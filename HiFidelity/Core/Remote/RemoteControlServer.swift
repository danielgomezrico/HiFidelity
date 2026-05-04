//
//  RemoteControlServer.swift
//  HiFidelity
//
//  HTTP remote-control server skeleton (M1). Routes are added in later
//  milestones (M2+). Off-by-default; gated on `RemoteSettings.isEnabled`.
//

import Foundation
import FlyingFox

/// Long-lived `@MainActor` singleton that owns the FlyingFox `HTTPServer`
/// instance and its lifecycle. Reads/writes must occur on the main actor;
/// route handlers (which run on FlyingFox's executor) explicitly hop here
/// via `MainActor.run` when they need to touch app state.
@MainActor
final class RemoteControlServer: ObservableObject {
    static let shared = RemoteControlServer()

    // MARK: - Published State

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16
    @Published private(set) var bonjourName: String

    // MARK: - Private

    private var server: HTTPServer?
    private var serverTask: Task<Void, Never>?

    private init() {
        // Resolve initial port + Bonjour name from UserDefaults via the
        // `RemoteSettings` accessors. These values are captured once at
        // server start; live updates happen through `restart()` after the
        // user edits Settings (M6).
        self.port = RemoteSettings.port
        self.bonjourName = RemoteSettings.bonjourName
    }

    // MARK: - Lifecycle

    /// Start the HTTP server. No-op if already running.
    func start() async throws {
        guard !isRunning else {
            Logger.debug("RemoteControlServer.start called while already running; ignoring")
            return
        }

        // Re-read settings each start so port / name changes take effect.
        let resolvedPort = RemoteSettings.port
        let resolvedName = RemoteSettings.bonjourName

        let httpServer = HTTPServer(port: resolvedPort)
        await registerRoutes(on: httpServer)

        // FlyingFox's `run()` blocks for the lifetime of the server; we
        // launch it on a detached Task so callers return as soon as the
        // listener is up.
        let runTask = Task { [weak self] in
            do {
                try await httpServer.run()
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        Logger.error("RemoteControlServer run loop ended with error: \(error)")
                        self?.isRunning = false
                    }
                }
            }
        }

        do {
            try await httpServer.waitUntilListening(timeout: 5)
        } catch {
            runTask.cancel()
            await httpServer.stop(timeout: 1)
            Logger.error("RemoteControlServer failed to listen on port \(resolvedPort): \(error)")
            throw error
        }

        self.server = httpServer
        self.serverTask = runTask
        self.port = resolvedPort
        self.bonjourName = resolvedName
        self.isRunning = true
        Logger.info("RemoteControlServer started on port \(resolvedPort)")
    }

    /// Stop the HTTP server. No-op if not running.
    func stop() async {
        guard let httpServer = server else {
            isRunning = false
            return
        }
        await httpServer.stop(timeout: 3)
        serverTask?.cancel()
        server = nil
        serverTask = nil
        isRunning = false
        Logger.info("RemoteControlServer stopped")
    }

    /// Convenience: stop then start. Used by Settings when the user edits
    /// the port or Bonjour name while the server is running.
    func restart() async throws {
        await stop()
        try await start()
    }

    // MARK: - Routes

    /// Register routes on the supplied `HTTPServer` instance.
    private func registerRoutes(on server: HTTPServer) async {
        await registerStateRoutes(on: server)
        await registerCommandRoutes(on: server)
        await registerBrowseRoutes(on: server)
    }

    /// M2 read-only routes: `/state` (current playback snapshot, ETag-keyed)
    /// and `/artwork/:trackId` (raw image bytes, content-addressable).
    private func registerStateRoutes(on server: HTTPServer) async {
        // GET /state — JSON snapshot of PlaybackController, hash-derived ETag.
        await server.appendRoute("GET /state") { request in
            let state = await MainActor.run { RemoteStateProvider.snapshot() }
            let data: Data
            do {
                data = try RemoteETag.canonicalJSONEncoder.encode(state)
            } catch {
                Logger.error("RemoteControlServer /state encode failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
            let tag = RemoteETag.etag(forJSON: data)
            if let inm = request.headers[HTTPHeader("If-None-Match")], inm == tag {
                return HTTPResponse(
                    statusCode: .notModified,
                    headers: [.eTag: tag, HTTPHeader("Cache-Control"): "no-store"]
                )
            }
            return HTTPResponse(
                statusCode: .ok,
                headers: [
                    .contentType: "application/json; charset=utf-8",
                    .eTag: tag,
                    HTTPHeader("Cache-Control"): "no-store"
                ],
                body: data
            )
        }

        // GET /artwork/:trackId — raw bytes; content-addressable so any
        // matching ETag short-circuits to 304 without touching the DB.
        await server.appendRoute("GET /artwork/:trackId") { request in
            guard let raw = request.routeParameters["trackId"],
                  let trackId = Int64(raw) else {
                return HTTPResponse(
                    statusCode: .badRequest,
                    headers: [.contentType: "application/json; charset=utf-8"],
                    body: Data(#"{"error":"invalid trackId"}"#.utf8)
                )
            }
            let tag = "\"track-\(trackId)\""
            if let inm = request.headers[HTTPHeader("If-None-Match")], inm == tag {
                return HTTPResponse(
                    statusCode: .notModified,
                    headers: [.eTag: tag, HTTPHeader("Cache-Control"): "public, max-age=31536000, immutable"]
                )
            }
            do {
                guard let result = try RemoteArtworkLoader.data(forTrackId: trackId) else {
                    return HTTPResponse(statusCode: .notFound)
                }
                return HTTPResponse(
                    statusCode: .ok,
                    headers: [
                        .contentType: result.contentType,
                        .eTag: tag,
                        HTTPHeader("Cache-Control"): "public, max-age=31536000, immutable"
                    ],
                    body: result.data
                )
            } catch {
                Logger.error("RemoteControlServer /artwork/\(trackId) DB read failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
    }
}

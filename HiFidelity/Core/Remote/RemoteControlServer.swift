//
//  RemoteControlServer.swift
//  HiFidelity
//
//  HTTP remote-control server skeleton (M1). Routes are added in later
//  milestones (M2+). Off-by-default; gated on `RemoteSettings.isEnabled`.
//

import Foundation
import FlyingFox
import Network

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
    @Published private(set) var primaryURL: URL?
    @Published private(set) var allURLs: [URL] = []

    // MARK: - Private

    private var server: HTTPServer?
    private var serverTask: Task<Void, Never>?
    private var netService: NetService?
    private var bonjourDelegate: RemoteBonjourDelegate?
    private var pathMonitor: NWPathMonitor?

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

        // Publish Bonjour AFTER the listener is up. NetService runs on the
        // main run loop; we are already on @MainActor here.
        publishBonjour(name: resolvedName, port: resolvedPort)

        // Start watching interface changes so Settings always shows live
        // URLs after Wi-Fi joins/leaves, Tailscale toggles, etc.
        startPathMonitor()
        refreshAllURLs()
    }

    /// Stop the HTTP server. No-op if not running.
    func stop() async {
        stopPathMonitor()
        unpublishBonjour()
        primaryURL = nil
        allURLs = []
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

    // MARK: - Bonjour

    /// Publish the HTTP service over mDNS as `_hifidelity._tcp`. Auto-rename
    /// is allowed; `RemoteBonjourDelegate` writes the resolved name back to
    /// `bonjourName` so Settings reflects reality.
    private func publishBonjour(name: String, port: UInt16) {
        let svc = NetService(
            domain: "local.",
            type: "_hifidelity._tcp.",
            name: name,
            port: Int32(port)
        )
        let delegate = RemoteBonjourDelegate { [weak self] resolvedName in
            Task { @MainActor in
                guard let self else { return }
                if self.bonjourName != resolvedName {
                    self.bonjourName = resolvedName
                }
            }
        }
        svc.delegate = delegate
        svc.schedule(in: .main, forMode: .default)
        svc.publish()
        self.netService = svc
        self.bonjourDelegate = delegate
    }

    private func unpublishBonjour() {
        netService?.stop()
        netService?.remove(from: .main, forMode: .default)
        netService = nil
        bonjourDelegate = nil
    }

    // MARK: - Path monitoring + URL list

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllURLs()
            }
        }
        monitor.start(queue: .main)
        self.pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// Refresh the list of URLs that point at this server. Called whenever
    /// `NWPathMonitor` reports an interface change.
    func refreshAllURLs() {
        let port = self.port
        let ips = NetworkInterfaceLister.activeIPv4Addresses()
        var urls: [URL] = []
        for ip in ips {
            if let url = URL(string: "http://\(ip):\(port)/") {
                urls.append(url)
            }
        }
        self.allURLs = urls

        // Primary URL: prefer the Bonjour <name>.local form (works on all
        // Apple devices, falls through router NAT). Fallback to the first
        // en* IPv4 address if Bonjour is not yet published.
        if !bonjourName.isEmpty {
            self.primaryURL = URL(string: "http://\(bonjourName).local:\(port)/")
        } else {
            self.primaryURL = urls.first
        }
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
        await registerWebUIRoutes(on: server)
    }

    /// Static-file routes serving the bundled HTML/CSS/JS web client.
    /// HEAD mirrors GET (RFC 9110): same headers, empty body.
    private func registerWebUIRoutes(on server: HTTPServer) async {
        let webSubdir = "RemoteControl/web"
        let indexHandler = BundleHTTPHandler(
            resourceName: "index",
            resourceExtension: "html",
            subdirectory: webSubdir,
            contentType: "text/html; charset=utf-8",
            cacheControl: "no-cache"
        )
        let appJsHandler = BundleHTTPHandler(
            resourceName: "app",
            resourceExtension: "js",
            subdirectory: webSubdir,
            contentType: "application/javascript; charset=utf-8"
        )
        let styleCssHandler = BundleHTTPHandler(
            resourceName: "style",
            resourceExtension: "css",
            subdirectory: webSubdir,
            contentType: "text/css; charset=utf-8"
        )
        await server.appendRoute("GET /", to: indexHandler)
        await server.appendRoute("GET /index.html", to: indexHandler)
        await server.appendRoute("GET /assets/app.js", to: appJsHandler)
        await server.appendRoute("GET /assets/style.css", to: styleCssHandler)

        // HEAD: rerun the GET path but drop the body. (B006)
        await server.appendRoute("HEAD /") { request in
            await stripBody(try await indexHandler.handleRequest(request))
        }
        await server.appendRoute("HEAD /index.html") { request in
            await stripBody(try await indexHandler.handleRequest(request))
        }
        await server.appendRoute("HEAD /assets/app.js") { request in
            await stripBody(try await appJsHandler.handleRequest(request))
        }
        await server.appendRoute("HEAD /assets/style.css") { request in
            await stripBody(try await styleCssHandler.handleRequest(request))
        }
    }

    /// M2 read-only routes: `/state` (current playback snapshot, ETag-keyed)
    /// and `/artwork/:trackId` (raw image bytes, content-addressable).
    /// HEAD mirrors GET (RFC 9110): same headers, empty body.
    private func registerStateRoutes(on server: HTTPServer) async {
        // GET /state — JSON snapshot of PlaybackController, hash-derived ETag.
        let stateHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
            let state = await MainActor.run { RemoteStateProvider.snapshot() }
            let data: Data
            do {
                data = try RemoteETag.canonicalJSONEncoder.encode(state)
            } catch {
                Logger.error("RemoteControlServer /state encode failed: \(error)")
                return RemoteResponse.serverError("state encode failed")
            }
            let tag = RemoteETag.etag(forJSON: data)
            if let inm = request.headers[HTTPHeader("If-None-Match")], inm == tag {
                let headers: HTTPHeaders = [.eTag: tag, HTTPHeader("Cache-Control"): "no-store"]
                return HTTPResponse(statusCode: .notModified, headers: headers)
            }
            let headers: HTTPHeaders = [
                .contentType: "application/json; charset=utf-8",
                .eTag: tag,
                HTTPHeader("Cache-Control"): "no-store"
            ]
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        }
        await server.appendRoute("GET /state", handler: stateHandler)
        await server.appendRoute("HEAD /state") { request in
            await stripBody(try await stateHandler(request))
        }

        // GET /artwork/:trackId — raw bytes; ETag derives from id PLUS a
        // short content fingerprint so deleted/replaced artwork yields a
        // fresh tag and never serves a 304 for a missing track.
        let artworkHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
            guard let raw = request.routeParameters["trackId"],
                  let trackId = Int64(raw) else {
                return RemoteResponse.badRequest("invalid trackId")
            }
            do {
                // Existence check first — return 404 before any ETag work.
                guard let result = try RemoteArtworkLoader.data(forTrackId: trackId) else {
                    return RemoteResponse.notFound("not found")
                }
                let tag = RemoteETag.artworkETag(trackId: trackId, bytes: result.data)
                if let inm = request.headers[HTTPHeader("If-None-Match")], inm == tag {
                    let headers: HTTPHeaders = [
                        .eTag: tag,
                        HTTPHeader("Cache-Control"): "public, max-age=31536000, immutable"
                    ]
                    return HTTPResponse(statusCode: .notModified, headers: headers)
                }
                let headers: HTTPHeaders = [
                    .contentType: result.contentType,
                    .eTag: tag,
                    HTTPHeader("Cache-Control"): "public, max-age=31536000, immutable"
                ]
                return HTTPResponse(statusCode: .ok, headers: headers, body: result.data)
            } catch {
                Logger.error("RemoteControlServer /artwork/\(trackId) DB read failed: \(error)")
                return RemoteResponse.serverError("artwork read failed")
            }
        }
        await server.appendRoute("GET /artwork/:trackId", handler: artworkHandler)
        await server.appendRoute("HEAD /artwork/:trackId") { request in
            await stripBody(try await artworkHandler(request))
        }
    }
}

/// Drop the body from an HTTPResponse, preserving status code and headers.
/// Used for HEAD handlers that mirror GET. (B006)
@Sendable
func stripBody(_ response: HTTPResponse) async -> HTTPResponse {
    HTTPResponse(statusCode: response.statusCode, headers: response.headers, body: Data())
}

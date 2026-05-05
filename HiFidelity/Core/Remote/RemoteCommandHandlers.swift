//
//  RemoteCommandHandlers.swift
//  HiFidelity
//
//  HTTP command handler closures for the remote-control API. Every handler
//  hops to `MainActor.run` before touching `PlaybackController.shared`.
//  No new methods are added to `PlaybackController` — handlers call only
//  existing methods.
//

import Foundation
import FlyingFox

extension RemoteControlServer {
    /// Register the M3 command (POST) routes on the supplied server.
    /// Call from `registerRoutes(on:)`.
    func registerCommandRoutes(on server: HTTPServer) async {
        // ---- Transport ----
        await server.appendRoute("POST /play") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.play() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /pause") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.pause() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /toggle") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.togglePlayPause() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /next") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.next() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /previous") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.previous() }
            return RemoteResponse.ok
        }

        // ---- Seeking ----
        await server.appendRoute("POST /seek") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(SeekRequest.self, from: body) else {
                return RemoteResponse.badRequest("invalid body")
            }
            let pre = max(0.0, req.seconds)
            await MainActor.run {
                let dur = PlaybackController.shared.duration
                PlaybackController.shared.seek(to: dur > 0 ? min(pre, dur) : pre)
            }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /seekRelative") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(SeekRelativeRequest.self, from: body) else {
                return RemoteResponse.badRequest("invalid body")
            }
            let delta = req.delta
            await MainActor.run {
                if delta >= 0 {
                    PlaybackController.shared.seekForward(delta)
                } else {
                    PlaybackController.shared.seekBackward(-delta)
                }
            }
            return RemoteResponse.ok
        }

        // ---- Volume / Mute ----
        await server.appendRoute("POST /volume") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(VolumeRequest.self, from: body) else {
                return RemoteResponse.badRequest("invalid body")
            }
            let clamped = max(0.0, min(1.0, req.volume))
            await MainActor.run { PlaybackController.shared.setVolume(clamped) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /mute") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.toggleMute() }
            return RemoteResponse.ok
        }

        // ---- Modes ----
        await server.appendRoute("POST /shuffle") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.toggleShuffle() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /repeat") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.toggleRepeat() }
            return RemoteResponse.ok
        }

        // ---- Favorites ----
        // No-op when currentTrack.trackId == nil — matches existing behavior
        // at PlaybackController+Favorites.swift:16. Documented, not "fixed."
        await server.appendRoute("POST /favorite") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.toggleFavorite() }
            return RemoteResponse.ok
        }

        // ---- Queue ops ----
        await server.appendRoute("POST /queue/play") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(IndexRequest.self, from: body),
                  req.index >= 0 else {
                return RemoteResponse.badRequest("invalid body")
            }
            await MainActor.run { PlaybackController.shared.playTrackAtIndex(req.index) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /queue/remove") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(IndexRequest.self, from: body),
                  req.index >= 0 else {
                return RemoteResponse.badRequest("invalid body")
            }
            await MainActor.run { PlaybackController.shared.removeFromQueue(at: req.index) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /queue/move") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(MoveRequest.self, from: body),
                  req.from >= 0, req.to >= 0 else {
                return RemoteResponse.badRequest("invalid body")
            }
            await MainActor.run { PlaybackController.shared.moveQueueItem(from: req.from, to: req.to) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /queue/clear") { request in
            guard isRemoteOriginAllowed(request) else { return RemoteResponse.forbidden("origin not allowed") }
            await MainActor.run { PlaybackController.shared.clearQueue() }
            return RemoteResponse.ok
        }
    }

}

/// Non-isolated namespace for HTTP response helpers used by handler closures
/// that run on FlyingFox's executor (outside `@MainActor`).
enum RemoteResponse {
    static var ok: HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: Data(#"{"ok":true}"#.utf8)
        )
    }

    static func badRequest(_ message: String) -> HTTPResponse {
        errorJSON(.badRequest, message)
    }

    static func forbidden(_ message: String) -> HTTPResponse {
        errorJSON(.forbidden, message)
    }

    static func notFound(_ message: String) -> HTTPResponse {
        errorJSON(.notFound, message)
    }

    static func serverError(_ message: String) -> HTTPResponse {
        errorJSON(.internalServerError, message)
    }

    /// Build a JSON error envelope `{"error":"<msg>"}` with the standard
    /// content-type. Single source of truth for non-2xx response shape.
    static func errorJSON(_ status: HTTPStatusCode, _ message: String) -> HTTPResponse {
        let payload: Data
        if let encoded = try? JSONSerialization.data(withJSONObject: ["error": message]) {
            payload = encoded
        } else {
            payload = Data(#"{"error":"error"}"#.utf8)
        }
        return HTTPResponse(
            statusCode: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: payload
        )
    }
}

/// Same-origin guard for write endpoints (v1 hardening only — no token,
/// no pairing). The browser always sends Origin matching the page it
/// loaded, and the page was loaded from this same server, so its host
/// must equal the request's Host header. That's the entire check.
///
/// Allows: absent Origin (curl / native clients) or Origin host:port
/// case-insensitively equal to the request Host header. Anything else
/// is rejected — handlers return `RemoteResponse.forbidden(...)`.
@Sendable
func isRemoteOriginAllowed(_ request: HTTPRequest) -> Bool {
    let originValue = request.headers[HTTPHeader("Origin")]
    guard let originValue, !originValue.isEmpty else { return true }
    guard let originURL = URL(string: originValue), let originHost = originURL.host else {
        return false
    }
    guard let hostHeader = request.headers[HTTPHeader("Host")], !hostHeader.isEmpty else {
        return false
    }
    // Compare host:port. Origin's port is implicit (80 for http, 443 for
    // https) when omitted; Host always omits 80/443. Build canonical
    // "host:port" forms on both sides.
    let originPort = originURL.port ?? (originURL.scheme == "https" ? 443 : 80)
    let originCanonical = "\(originHost):\(originPort)".lowercased()

    let hostCanonical: String
    if hostHeader.contains(":") {
        hostCanonical = hostHeader.lowercased()
    } else {
        // Bare host = default port. We're plain HTTP, so 80.
        hostCanonical = "\(hostHeader):80".lowercased()
    }
    return originCanonical == hostCanonical
}

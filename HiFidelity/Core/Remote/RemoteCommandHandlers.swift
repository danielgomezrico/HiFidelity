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
        await server.appendRoute("POST /play") { _ in
            await MainActor.run { PlaybackController.shared.play() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /pause") { _ in
            await MainActor.run { PlaybackController.shared.pause() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /toggle") { _ in
            await MainActor.run { PlaybackController.shared.togglePlayPause() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /next") { _ in
            await MainActor.run { PlaybackController.shared.next() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /previous") { _ in
            await MainActor.run { PlaybackController.shared.previous() }
            return RemoteResponse.ok
        }

        // ---- Seeking ----
        await server.appendRoute("POST /seek") { request in
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
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(VolumeRequest.self, from: body) else {
                return RemoteResponse.badRequest("invalid body")
            }
            let clamped = max(0.0, min(1.0, req.volume))
            await MainActor.run { PlaybackController.shared.setVolume(clamped) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /mute") { _ in
            await MainActor.run { PlaybackController.shared.toggleMute() }
            return RemoteResponse.ok
        }

        // ---- Modes ----
        await server.appendRoute("POST /shuffle") { _ in
            await MainActor.run { PlaybackController.shared.toggleShuffle() }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /repeat") { _ in
            await MainActor.run { PlaybackController.shared.toggleRepeat() }
            return RemoteResponse.ok
        }

        // ---- Favorites ----
        // No-op when currentTrack.trackId == nil — matches existing behavior
        // at PlaybackController+Favorites.swift:16. Documented, not "fixed."
        await server.appendRoute("POST /favorite") { _ in
            await MainActor.run { PlaybackController.shared.toggleFavorite() }
            return RemoteResponse.ok
        }

        // ---- Queue ops ----
        await server.appendRoute("POST /queue/play") { request in
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(IndexRequest.self, from: body),
                  req.index >= 0 else {
                return RemoteResponse.badRequest("invalid body")
            }
            await MainActor.run { PlaybackController.shared.playTrackAtIndex(req.index) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /queue/remove") { request in
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(IndexRequest.self, from: body),
                  req.index >= 0 else {
                return RemoteResponse.badRequest("invalid body")
            }
            await MainActor.run { PlaybackController.shared.removeFromQueue(at: req.index) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /queue/move") { request in
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(MoveRequest.self, from: body),
                  req.from >= 0, req.to >= 0 else {
                return RemoteResponse.badRequest("invalid body")
            }
            await MainActor.run { PlaybackController.shared.moveQueueItem(from: req.from, to: req.to) }
            return RemoteResponse.ok
        }
        await server.appendRoute("POST /queue/clear") { _ in
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
        let payload: Data
        if let encoded = try? JSONSerialization.data(withJSONObject: ["error": message]) {
            payload = encoded
        } else {
            payload = Data(#"{"error":"bad request"}"#.utf8)
        }
        return HTTPResponse(
            statusCode: .badRequest,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: payload
        )
    }
}

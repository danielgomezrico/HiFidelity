//
//  RemoteBrowseHandlers.swift
//  HiFidelity
//
//  Read-only library browse routes (GET) and three queue-from-browse
//  POST routes that bridge browse → playback. Read handlers run off
//  main on the FlyingFox executor; the three POST handlers hop to
//  MainActor.run before invoking the queue mutators.
//

import Foundation
import FlyingFox
import GRDB

extension RemoteControlServer {
    /// Register the M4 browse + queue-from-browse routes on the server.
    func registerBrowseRoutes(on server: HTTPServer) async {
        await registerListRoutes(on: server)
        await registerEntityTrackRoutes(on: server)
        await registerQueueFromBrowseRoutes(on: server)
    }

    // MARK: - List endpoints

    private func registerListRoutes(on server: HTTPServer) async {
        // GET /tracks?limit=&offset=&q=
        await server.appendRoute("GET /tracks") { request in
            let limit = clampLimit(request.query.first(where: { $0.name == "limit" })?.value, fallback: 100, max: 10_000)
            let offset = max(0, Int(request.query.first(where: { $0.name == "offset" })?.value ?? "") ?? 0)
            let q = request.query.first(where: { $0.name == "q" })?.value
            do {
                if let q, !q.isEmpty {
                    let tracks = try await DatabaseManager.shared.searchTracks(query: q, limit: limit)
                    let dtos = tracks.compactMap { RemoteTrack($0) }
                    return jsonResponse(RemoteTracksPage(tracks: dtos, total: dtos.count, limit: limit, offset: 0))
                }
                let (page, total) = try await fetchTracksPage(limit: limit, offset: offset)
                return jsonResponse(RemoteTracksPage(tracks: page, total: total, limit: limit, offset: offset))
            } catch {
                Logger.error("RemoteControlServer /tracks failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }

        // GET /albums?limit=&offset=&q=
        await server.appendRoute("GET /albums") { request in
            let limit = clampLimit(request.query.first(where: { $0.name == "limit" })?.value, fallback: 100, max: 10_000)
            let offset = max(0, Int(request.query.first(where: { $0.name == "offset" })?.value ?? "") ?? 0)
            let q = request.query.first(where: { $0.name == "q" })?.value
            do {
                let albums: [Album]
                if let q, !q.isEmpty {
                    albums = try await DatabaseManager.shared.searchAlbums(query: q, limit: limit)
                } else {
                    albums = try await DatabaseManager.shared.dbQueue.read { db -> [Album] in
                        try Album
                            .order(Album.Columns.sortName)
                            .limit(limit, offset: offset)
                            .fetchAll(db)
                    }
                }
                let dtos = albums.compactMap { RemoteAlbum($0) }
                return jsonResponse(dtos)
            } catch {
                Logger.error("RemoteControlServer /albums failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }

        // GET /artists?limit=&offset=&q=
        await server.appendRoute("GET /artists") { request in
            let limit = clampLimit(request.query.first(where: { $0.name == "limit" })?.value, fallback: 100, max: 10_000)
            let offset = max(0, Int(request.query.first(where: { $0.name == "offset" })?.value ?? "") ?? 0)
            let q = request.query.first(where: { $0.name == "q" })?.value
            do {
                let artists: [Artist]
                if let q, !q.isEmpty {
                    artists = try await DatabaseManager.shared.searchArtists(query: q, limit: limit)
                } else {
                    artists = try await DatabaseManager.shared.dbQueue.read { db -> [Artist] in
                        try Artist
                            .order(Artist.Columns.sortName)
                            .limit(limit, offset: offset)
                            .fetchAll(db)
                    }
                }
                let dtos = artists.compactMap { RemoteArtist($0) }
                return jsonResponse(dtos)
            } catch {
                Logger.error("RemoteControlServer /artists failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }

        // GET /playlists
        await server.appendRoute("GET /playlists") { _ in
            do {
                let playlists = try await DatabaseManager.shared.dbQueue.read { db -> [Playlist] in
                    try Playlist
                        .order(Playlist.Columns.sortOrder, Playlist.Columns.name)
                        .fetchAll(db)
                }
                let dtos = playlists.compactMap { RemotePlaylist($0) }
                return jsonResponse(dtos)
            } catch {
                Logger.error("RemoteControlServer /playlists failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
    }

    // MARK: - Per-entity track listings

    private func registerEntityTrackRoutes(on server: HTTPServer) async {
        // GET /albums/:albumId/tracks
        await server.appendRoute("GET /albums/:albumId/tracks") { request in
            guard let raw = request.routeParameters["albumId"], let id = Int64(raw) else {
                return RemoteResponse.badRequest("invalid albumId")
            }
            do {
                let tracks = try await DatabaseManager.shared.getTracksForAlbum(albumId: id)
                return jsonResponse(tracks.compactMap { RemoteTrack($0) })
            } catch {
                Logger.error("RemoteControlServer /albums/\(id)/tracks failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }

        // GET /artists/:artistId/tracks
        await server.appendRoute("GET /artists/:artistId/tracks") { request in
            guard let raw = request.routeParameters["artistId"], let id = Int64(raw) else {
                return RemoteResponse.badRequest("invalid artistId")
            }
            do {
                let tracks = try await DatabaseManager.shared.getTracksForArtist(artistId: id)
                return jsonResponse(tracks.compactMap { RemoteTrack($0) })
            } catch {
                Logger.error("RemoteControlServer /artists/\(id)/tracks failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }

        // GET /playlists/:id/tracks
        await server.appendRoute("GET /playlists/:playlistId/tracks") { request in
            guard let raw = request.routeParameters["playlistId"], let id = Int64(raw) else {
                return RemoteResponse.badRequest("invalid playlistId")
            }
            do {
                let tracks = try await DatabaseManager.shared.getTracksForPlaylist(playlistId: id)
                return jsonResponse(tracks.compactMap { RemoteTrack($0) })
            } catch {
                Logger.error("RemoteControlServer /playlists/\(id)/tracks failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
    }

    // MARK: - Queue-from-browse (POST)

    private func registerQueueFromBrowseRoutes(on server: HTTPServer) async {
        // POST /queue/playTracks { trackIds: [Int64], startAt: Int }
        await server.appendRoute("POST /queue/playTracks") { request in
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(PlayTracksRequest.self, from: body) else {
                return RemoteResponse.badRequest("invalid body")
            }
            guard !req.trackIds.isEmpty else {
                return RemoteResponse.badRequest("trackIds empty")
            }
            do {
                let tracks = try await fetchTracksByIds(req.trackIds)
                guard !tracks.isEmpty else {
                    return RemoteResponse.badRequest("no matching tracks")
                }
                let startAt = max(0, min(req.startAt, tracks.count - 1))
                await MainActor.run {
                    PlaybackController.shared.playTracks(tracks, startingAt: startAt)
                }
                return RemoteResponse.ok
            } catch {
                Logger.error("RemoteControlServer /queue/playTracks failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }

        // POST /queue/add { trackIds: [Int64] }
        await server.appendRoute("POST /queue/add") { request in
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(TrackIdsRequest.self, from: body) else {
                return RemoteResponse.badRequest("invalid body")
            }
            guard !req.trackIds.isEmpty else {
                return RemoteResponse.badRequest("trackIds empty")
            }
            do {
                let tracks = try await fetchTracksByIds(req.trackIds)
                guard !tracks.isEmpty else {
                    return RemoteResponse.badRequest("no matching tracks")
                }
                await MainActor.run {
                    PlaybackController.shared.addToQueue(tracks)
                }
                return RemoteResponse.ok
            } catch {
                Logger.error("RemoteControlServer /queue/add failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }

        // POST /queue/playNext { trackIds: [Int64] }
        await server.appendRoute("POST /queue/playNext") { request in
            guard let body = try? await request.bodyData,
                  let req = try? JSONDecoder().decode(TrackIdsRequest.self, from: body) else {
                return RemoteResponse.badRequest("invalid body")
            }
            guard !req.trackIds.isEmpty else {
                return RemoteResponse.badRequest("trackIds empty")
            }
            do {
                let tracks = try await fetchTracksByIds(req.trackIds)
                guard !tracks.isEmpty else {
                    return RemoteResponse.badRequest("no matching tracks")
                }
                // playNext(_:) inserts a single track immediately after the
                // current one. To preserve list order, insert in reverse —
                // each insert pushes earlier inserts down by one slot.
                await MainActor.run {
                    for t in tracks.reversed() {
                        PlaybackController.shared.playNext(t)
                    }
                }
                return RemoteResponse.ok
            } catch {
                Logger.error("RemoteControlServer /queue/playNext failed: \(error)")
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
    }
}

// MARK: - Helpers (file scope, non-isolated)

/// Encode any Encodable as JSON (sorted keys for cache-friendly output).
private func jsonResponse<T: Encodable>(_ value: T) -> HTTPResponse {
    do {
        let data = try RemoteETag.canonicalJSONEncoder.encode(value)
        return HTTPResponse(
            statusCode: .ok,
            headers: [
                .contentType: "application/json; charset=utf-8",
                HTTPHeader("Cache-Control"): "no-store"
            ],
            body: data
        )
    } catch {
        Logger.error("RemoteControlServer JSON encode failed: \(error)")
        return HTTPResponse(statusCode: .internalServerError)
    }
}

/// Clamp the user-supplied `limit` query param into a sane range.
private func clampLimit(_ raw: String?, fallback: Int, max upper: Int) -> Int {
    guard let raw, let n = Int(raw) else { return fallback }
    return Swift.max(1, Swift.min(n, upper))
}

/// Fetch a page of tracks (full schema, ordered by sort_artist/title).
private func fetchTracksPage(limit: Int, offset: Int) async throws -> ([RemoteTrack], Int) {
    try await DatabaseManager.shared.dbQueue.read { db -> ([RemoteTrack], Int) in
        let total = try Track.filter(Track.Columns.isDuplicate == false).fetchCount(db)
        let rows = try Track
            .filter(Track.Columns.isDuplicate == false)
            .order(Track.Columns.sortTitle, Track.Columns.title)
            .limit(limit, offset: offset)
            .fetchAll(db)
        let dtos = rows.compactMap { RemoteTrack($0) }
        return (dtos, total)
    }
}

/// Fetch full Track rows for the given DB ids in a single read transaction.
/// FULL schema (not lightweight) — the playback engine needs `url`.
private func fetchTracksByIds(_ ids: [Int64]) async throws -> [Track] {
    try await DatabaseManager.shared.dbQueue.read { db -> [Track] in
        let fetched = try Track.fetchAll(db, keys: ids)
        // Preserve caller-supplied order (DB returns in row order).
        let byId: [Int64: Track] = Dictionary(uniqueKeysWithValues: fetched.compactMap { t in
            guard let tid = t.trackId else { return nil }
            return (tid, t)
        })
        return ids.compactMap { byId[$0] }
    }
}

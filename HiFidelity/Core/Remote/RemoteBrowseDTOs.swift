//
//  RemoteBrowseDTOs.swift
//  HiFidelity
//
//  Wire DTOs for the M4 browse endpoints. All artwork blobs are dropped —
//  remote clients should fetch artwork separately via /artwork/:trackId
//  with the persistent ETag-driven cache.
//

import Foundation

/// Page wrapper for /tracks responses.
struct RemoteTracksPage: Encodable {
    let tracks: [RemoteTrack]
    let total: Int
    let limit: Int
    let offset: Int
}

/// Page wrapper for /albums responses.
struct RemoteAlbum: Encodable {
    let id: Int64
    let title: String
    let albumArtist: String?
    let year: String?
    let trackCount: Int
    let totalDuration: Double
    let releaseType: String?

    init?(_ a: Album) {
        guard let aid = a.id else { return nil }
        self.id = aid
        self.title = a.title
        self.albumArtist = a.albumArtist
        self.year = a.year
        self.trackCount = a.trackCount
        self.totalDuration = a.totalDuration
        self.releaseType = a.releaseType
        // INVARIANT: a.artworkData is intentionally never read here.
    }
}

struct RemoteArtist: Encodable {
    let id: Int64
    let name: String
    let trackCount: Int
    let albumCount: Int

    init?(_ a: Artist) {
        guard let aid = a.id else { return nil }
        self.id = aid
        self.name = a.name
        self.trackCount = a.trackCount
        self.albumCount = a.albumCount
        // INVARIANT: a.artworkData is intentionally never read here.
    }
}

struct RemotePlaylist: Encodable {
    let id: Int64
    let name: String
    let description: String?
    let trackCount: Int
    let totalDuration: Double
    let isFavorite: Bool
    let isSmart: Bool
    let playCount: Int

    init?(_ p: Playlist) {
        guard let pid = p.id else { return nil }
        self.id = pid
        self.name = p.name
        self.description = p.description
        self.trackCount = p.trackCount
        self.totalDuration = p.totalDuration
        self.isFavorite = p.isFavorite
        self.isSmart = p.isSmart
        self.playCount = p.playCount
        // INVARIANT: p.customArtworkData is intentionally never read here.
    }
}

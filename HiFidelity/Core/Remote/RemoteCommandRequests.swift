//
//  RemoteCommandRequests.swift
//  HiFidelity
//
//  Strict-typed `Decodable` request bodies for the HTTP command routes.
//  Decoding failures cause handlers to return 400 Bad Request — never
//  silently fall back to defaults.
//

import Foundation

struct SeekRequest: Decodable {
    let seconds: Double
}

struct SeekRelativeRequest: Decodable {
    let delta: Double
}

struct VolumeRequest: Decodable {
    let volume: Double
}

struct IndexRequest: Decodable {
    let index: Int
}

struct MoveRequest: Decodable {
    let from: Int
    let to: Int
}

struct TrackIdsRequest: Decodable {
    let trackIds: [Int64]
}

struct PlayTracksRequest: Decodable {
    let trackIds: [Int64]
    let startAt: Int
}

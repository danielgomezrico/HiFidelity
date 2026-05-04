//
//  ETag.swift
//  HiFidelity
//
//  Hash-derived ETag generation for the HTTP remote-control state route.
//  Using SHA256 of canonicalized JSON avoids the willSet-vs-didSet race
//  that a Combine `objectWillChange`-incremented counter would create.
//

import Foundation
import CryptoKit

enum RemoteETag {
    /// Build a quoted, weak-style ETag from the given JSON payload bytes.
    /// Only the first 16 hex characters of SHA-256 are used — collision
    /// risk for our state DTO is negligible and short tags keep the header
    /// small.
    static func etag(forJSON data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\"v" + hex.prefix(16) + "\""
    }

    /// JSON encoder configured for deterministic byte output across calls
    /// with equal state. Sorted keys are required so two equivalent states
    /// hash to the same ETag.
    static let canonicalJSONEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()
}

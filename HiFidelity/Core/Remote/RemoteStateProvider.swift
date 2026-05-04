//
//  RemoteStateProvider.swift
//  HiFidelity
//
//  Snapshots `PlaybackController.shared` into a wire-safe `RemoteState`
//  DTO. Always invoked on the main actor — `PlaybackController` exposes
//  `@Published` properties and is not an actor, so reads must occur on
//  the main thread.
//

import Foundation

enum RemoteStateProvider {
    /// Capture a snapshot of `PlaybackController.shared`. MUST be called
    /// on the main actor; the `@MainActor` annotation enforces this.
    @MainActor
    static func snapshot() -> RemoteState {
        let pc = PlaybackController.shared
        let mode: String
        switch pc.repeatMode {
        case .off: mode = "off"
        case .all: mode = "all"
        case .one: mode = "one"
        }
        let queueDTO = pc.queue.compactMap { RemoteTrack($0) }
        let currentDTO = pc.currentTrack.flatMap { RemoteTrack($0) }
        let streamDTO = pc.currentStreamInfo.map { RemoteStreamInfo($0) }
        return RemoteState(
            isPlaying: pc.isPlaying,
            currentTime: pc.currentTime,
            duration: pc.duration,
            progress: pc.progress,
            volume: pc.volume,
            isMuted: pc.isMuted,
            repeatMode: mode,
            isShuffleEnabled: pc.isShuffleEnabled,
            currentTrack: currentDTO,
            queue: queueDTO,
            currentQueueIndex: pc.currentQueueIndex,
            stream: streamDTO
        )
    }
}

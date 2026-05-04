//
//  RemoteBonjourDelegate.swift
//  HiFidelity
//
//  NetServiceDelegate that captures the published name (which Bonjour may
//  rename on collision, e.g. "HiFidelity (2)") and surfaces it back to
//  RemoteControlServer.
//

import Foundation

final class RemoteBonjourDelegate: NSObject, NetServiceDelegate {
    private let onResolved: @Sendable (String) -> Void

    init(onResolved: @escaping @Sendable (String) -> Void) {
        self.onResolved = onResolved
    }

    func netServiceDidPublish(_ sender: NetService) {
        Logger.info("Bonjour: published _hifidelity._tcp as \"\(sender.name)\" on port \(sender.port)")
        onResolved(sender.name)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Logger.error("Bonjour: failed to publish _hifidelity._tcp: \(errorDict)")
    }

    func netServiceDidStop(_ sender: NetService) {
        Logger.debug("Bonjour: stopped publishing _hifidelity._tcp \"\(sender.name)\"")
    }
}

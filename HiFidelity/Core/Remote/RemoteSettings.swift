//
//  RemoteSettings.swift
//  HiFidelity
//
//  UserDefaults keys + read accessors for the HTTP remote-control feature.
//

import Foundation

/// Centralized accessors for the remote-control UserDefaults keys.
/// Single read site so the rest of the codebase can stay UserDefaults-string free.
enum RemoteSettings {
    /// UserDefaults key names. Keep in sync with `@AppStorage` keys in
    /// `RemoteControlSettings.swift` (M6).
    enum Keys {
        static let enabled = "remote.enabled"
        static let port = "remote.port"
        static let bonjourName = "remote.bonjourName"
    }

    /// Whether the user has enabled the HTTP remote-control server.
    /// Default: `false` (off, opt-in feature).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    /// Default TCP port the server binds to. macOS sandbox blocks ports < 1024
    /// for non-root processes, so we default to a high IANA-unassigned port.
    static let defaultPort: UInt16 = 7666

    /// User-configured port, clamped into a safe sandboxed range.
    static var port: UInt16 {
        let raw = UserDefaults.standard.object(forKey: Keys.port) as? Int
        guard let raw, raw >= 1024, raw <= 65535 else { return defaultPort }
        return UInt16(raw)
    }

    /// Resolved Bonjour service name. Falls back to the Mac's localized name,
    /// then to a fixed string so the field is never empty.
    static var bonjourName: String {
        if let stored = UserDefaults.standard.string(forKey: Keys.bonjourName),
           !stored.trimmingCharacters(in: .whitespaces).isEmpty {
            return stored
        }
        if let host = ProcessInfo.processInfo.hostName.split(separator: ".").first,
           !host.isEmpty {
            return String(host)
        }
        return "HiFidelity"
    }
}

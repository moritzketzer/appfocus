// Sources/Daemon/Config.swift
import Foundation

struct AppFocusConfig: Codable {
    var backend: String
    var yabaiPath: String
    var aliases: [String: String]
    var reopenStrategies: [String: ReopenStrategy]
    var pollIntervalMs: Int
    var kanataEnabled: Bool = true
    var kanataPort: Int = 7070

    enum CodingKeys: String, CodingKey {
        case backend
        case yabaiPath = "yabai_path"
        case aliases
        case reopenStrategies = "reopen_strategies"
        case pollIntervalMs = "poll_interval_ms"
        case kanataEnabled = "kanata_enabled"
        case kanataPort = "kanata_port"
    }

    static let `default` = AppFocusConfig(
        backend: "yabai",
        yabaiPath: "/etc/profiles/per-user/\(NSUserName())/bin/yabai",
        aliases: [:],
        reopenStrategies: ["*": .reopen],
        pollIntervalMs: 1000,
        kanataEnabled: true,
        kanataPort: 7070
    )

    static func load() -> AppFocusConfig {
        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSHomeDirectory() + "/.config"
        let path = xdgConfig + "/appfocus/config.json"

        guard let data = FileManager.default.contents(atPath: path) else {
            Log.info("No config at \(path), using defaults")
            return .default
        }

        do {
            let config = try JSONDecoder().decode(AppFocusConfig.self, from: data)
            Log.info("Loaded config from \(path)")
            return config
        } catch {
            Log.error("Failed to parse config: \(error). Using defaults.")
            return .default
        }
    }

    /// Resolve an app name through the alias map. Returns canonical name.
    func resolveAlias(_ name: String) -> String {
        return aliases[name] ?? name
    }

    /// Get reopen strategy for an app. Falls back to "*" default, then .reopen.
    func reopenStrategy(for appName: String) -> ReopenStrategy {
        return reopenStrategies[appName]
            ?? reopenStrategies["*"]
            ?? .reopen
    }
}

extension AppFocusConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decode(String.self, forKey: .backend)
        yabaiPath = try c.decode(String.self, forKey: .yabaiPath)
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        reopenStrategies = try c.decodeIfPresent([String: ReopenStrategy].self, forKey: .reopenStrategies) ?? ["*": .reopen]
        pollIntervalMs = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 1000
        kanataEnabled = try c.decodeIfPresent(Bool.self, forKey: .kanataEnabled) ?? true
        kanataPort = try c.decodeIfPresent(Int.self, forKey: .kanataPort) ?? 7070
    }
}

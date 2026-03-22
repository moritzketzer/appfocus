// Sources/Daemon/StateStore.swift
import Foundation

final class StateStore {
    private var states: [String: AppState] = [:]
    private var lastFocusedApp: String?
    private let stateDir: String
    private let lock = NSLock()

    init(stateDir: String = SocketPath.stateDir) {
        self.stateDir = stateDir
        try? FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true)
    }

    /// Get state for an app (loads from disk on first access).
    func state(for appName: String) -> AppState {
        lock.lock()
        defer { lock.unlock() }

        if let cached = states[appName] { return cached }

        let loaded = loadFromDisk(appName: appName)
        states[appName] = loaded
        return loaded
    }

    /// Update state for an app and flush to disk.
    func update(appName: String, mutate: (inout AppState) -> Void) {
        lock.lock()
        var s = states[appName] ?? loadFromDisk(appName: appName)
        mutate(&s)
        states[appName] = s
        lock.unlock()

        flushToDisk(appName: appName, state: s)
    }

    /// Record a window focus change. Returns true if state actually changed.
    @discardableResult
    func recordFocus(appName: String, windowId: Int, space: Int? = nil) -> Bool {
        lock.lock()
        var s = states[appName] ?? loadFromDisk(appName: appName)
        if s.lastFocusedId == windowId {
            lock.unlock()
            return false
        }
        s.prevFocusedId = s.lastFocusedId
        s.lastFocusedId = windowId
        if let space = space { s.lastFocusedSpace = space }
        states[appName] = s
        lastFocusedApp = appName
        lock.unlock()

        flushToDisk(appName: appName, state: s)
        Log.debug("Focus: \(appName) \(s.prevFocusedId ?? -1) -> \(windowId)")
        return true
    }

    var globalLastFocusedApp: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastFocusedApp
    }

    var trackedAppCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return states.count
    }

    /// Return cached state without loading from disk (for status reporting).
    func stateIfCached(for appName: String) -> AppState? {
        lock.lock()
        defer { lock.unlock() }
        return states[appName]
    }

    // MARK: - Disk persistence

    private func asFilename(_ name: String) -> String {
        return name.lowercased().replacingOccurrences(
            of: "[^a-z0-9]+", with: "_",
            options: .regularExpression)
    }

    private func statePath(for appName: String) -> String {
        return stateDir + "/" + asFilename(appName) + ".json"
    }

    private func loadFromDisk(appName: String) -> AppState {
        let path = statePath(for: appName)
        guard let data = FileManager.default.contents(atPath: path) else {
            return AppState()
        }
        do {
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            Log.debug("loadFromDisk(\(appName)): \(error)")
            return AppState()
        }
    }

    private func flushToDisk(appName: String, state: AppState) {
        let path = statePath(for: appName)
        guard let data = try? JSONEncoder().encode(state) else {
            Log.error("Failed to encode state for \(appName)")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// Sources/Daemon/Log.swift
import Foundation

/// Minimal logger — writes to stderr with level prefix.
enum Log {
    static var debugEnabled: Bool = ProcessInfo.processInfo.environment["APPFOCUS_LOG"] == "debug"

    // Millisecond wall-clock timestamp on every line. The appfocus failure
    // class is timing (yabai hangs for seconds to minutes), so stamped lines
    // are worth the negligible per-line cost.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static func ts() -> String { stamp.string(from: Date()) }

    // Every write goes through the throwing API and discards its error.
    // Logging must never take the daemon down with it, and the legacy
    // `FileHandle.write(_:)` raises an ObjC exception Swift cannot catch when
    // the write fails — which is exactly what EPIPE on a stderr whose
    // terminal detached does.
    static func error(_ msg: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(ts()) [ERROR] \(msg)\n".utf8))
    }
    static func info(_ msg: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(ts()) [INFO] \(msg)\n".utf8))
    }
    static func debug(_ msg: String) {
        guard debugEnabled else { return }
        try? FileHandle.standardError.write(contentsOf: Data("\(ts()) [DEBUG] \(msg)\n".utf8))
    }
}

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

    static func error(_ msg: String) {
        FileHandle.standardError.write(Data("\(ts()) [ERROR] \(msg)\n".utf8))
    }
    static func info(_ msg: String) {
        FileHandle.standardError.write(Data("\(ts()) [INFO] \(msg)\n".utf8))
    }
    static func debug(_ msg: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("\(ts()) [DEBUG] \(msg)\n".utf8))
    }
}

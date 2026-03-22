// Sources/Daemon/Log.swift
import Foundation

/// Minimal logger — writes to stderr with level prefix.
enum Log {
    static var debugEnabled: Bool = ProcessInfo.processInfo.environment["APPFOCUS_LOG"] == "debug"

    static func error(_ msg: String) {
        FileHandle.standardError.write(Data("[ERROR] \(msg)\n".utf8))
    }
    static func info(_ msg: String) {
        FileHandle.standardError.write(Data("[INFO] \(msg)\n".utf8))
    }
    static func debug(_ msg: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("[DEBUG] \(msg)\n".utf8))
    }
}

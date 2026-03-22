// Sources/Common/CommandProtocol.swift
import Foundation

enum Command: Equatable {
    case jump(appName: String)
    case next
    case prev
    case status

    /// Parse a newline-terminated string into a Command.
    static func parse(_ line: String) -> Command? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "next" { return .next }
        if trimmed == "prev" { return .prev }
        if trimmed == "status" { return .status }
        if trimmed.hasPrefix("jump ") {
            let appName = String(trimmed.dropFirst(5))
                .trimmingCharacters(in: .whitespaces)
            guard !appName.isEmpty else { return nil }
            return .jump(appName: appName)
        }
        return nil
    }

    /// Serialize to wire format (newline-terminated string).
    func serialize() -> String {
        switch self {
        case .jump(let appName): return "jump \(appName)\n"
        case .next: return "next\n"
        case .prev: return "prev\n"
        case .status: return "status\n"
        }
    }
}

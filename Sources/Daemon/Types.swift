// Sources/Daemon/Types.swift
import Foundation

struct WindowInfo {
    let id: Int
    let appName: String
    let space: Int
    let isMinimized: Bool
    let role: String
    let title: String
    let hasAXReference: Bool

    var isStandardWindow: Bool { role != "AXHelpTag" && hasAXReference }

    /// Parse a WindowInfo from a yabai JSON dictionary.
    static func from(yabaiDict dict: [String: Any]) -> WindowInfo? {
        guard let id = dict["id"] as? Int,
              let app = dict["app"] as? String,
              let space = dict["space"] as? Int,
              let title = dict["title"] as? String
        else { return nil }
        let isMinimized = dict["is-minimized"] as? Int == 1
            || dict["is-minimized"] as? Bool == true
        let role = dict["role"] as? String ?? ""
        let hasAXRef = dict["has-ax-reference"] as? Int == 1
            || dict["has-ax-reference"] as? Bool == true
        return WindowInfo(id: id, appName: app, space: space,
                          isMinimized: isMinimized, role: role,
                          title: title, hasAXReference: hasAXRef)
    }
}

struct AppState: Codable {
    var lastFocusedId: Int?
    var prevFocusedId: Int?
    var lastFocusedSpace: Int?
    var ring: [Int]

    init() {
        self.lastFocusedId = nil
        self.prevFocusedId = nil
        self.lastFocusedSpace = nil
        self.ring = []
    }
}

enum ReopenStrategy: String, Codable {
    case reopen       // osascript: tell application "X" to reopen
    case makeWindow   // osascript: tell application "Finder" to make new Finder window
    case makeDocument // osascript: tell application "Safari" to make new document
}

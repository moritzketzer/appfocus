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
    /// AX subrole from yabai. This — not `role`, which is `AXWindow` for real
    /// windows AND every dialog alike — is what distinguishes a user-facing
    /// document window (`AXStandardWindow`) from ChatGPT/Codex's sticky
    /// floating overlays (`AXDialog`, `AXSystemDialog`).
    let subrole: String

    init(id: Int, appName: String, space: Int, isMinimized: Bool,
         role: String, title: String, hasAXReference: Bool,
         subrole: String = "AXStandardWindow") {
        self.id = id
        self.appName = appName
        self.space = space
        self.isMinimized = isMinimized
        self.role = role
        self.title = title
        self.hasAXReference = hasAXReference
        self.subrole = subrole
    }

    /// A user-facing standard window: eligible to be tracked, focused, and
    /// cycled. Overlays (dialogs, floating palettes) are deliberately excluded
    /// so they can never enter MRU state or become a jump/cycle target.
    var isStandardWindow: Bool { hasAXReference && subrole == "AXStandardWindow" }

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
        let subrole = dict["subrole"] as? String ?? ""
        let hasAXRef = dict["has-ax-reference"] as? Int == 1
            || dict["has-ax-reference"] as? Bool == true
        return WindowInfo(id: id, appName: app, space: space,
                          isMinimized: isMinimized, role: role,
                          title: title, hasAXReference: hasAXRef,
                          subrole: subrole)
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

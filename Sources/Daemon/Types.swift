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
    /// yabai's stable structural flags. Unlike `subrole` (a cached AX
    /// passthrough that yabai reports empty for real windows), these are
    /// yabai-computed and reliable — they are what classify overlays.
    let isSticky: Bool
    let isFloating: Bool
    /// yabai's has-focus flag from the snapshot. Only meaningful on windows
    /// parsed out of a full `queryAllWindows` dump; the WindowModel derives
    /// its focusedId from it.
    let hasFocus: Bool
    /// yabai's is-visible flag: the window is on the active Space (or
    /// sticky) and not hidden/minimized. Outcome verification uses it to
    /// distinguish a genuinely landed switch from the swoosh-off
    /// "focused but invisible" failure mode.
    let isVisible: Bool

    init(id: Int, appName: String, space: Int, isMinimized: Bool,
         role: String, title: String, hasAXReference: Bool,
         subrole: String = "AXStandardWindow",
         isSticky: Bool = false, isFloating: Bool = false,
         hasFocus: Bool = false, isVisible: Bool = false) {
        self.id = id
        self.appName = appName
        self.space = space
        self.isMinimized = isMinimized
        self.role = role
        self.title = title
        self.hasAXReference = hasAXReference
        self.subrole = subrole
        self.isSticky = isSticky
        self.isFloating = isFloating
        self.hasFocus = hasFocus
        self.isVisible = isVisible
    }

    /// A user-facing standard window: eligible to be tracked, focused, and
    /// cycled. Overlays (dialogs, floating palettes) are deliberately excluded
    /// so they can never enter MRU state or become a jump/cycle target.
    ///
    /// The old `subrole == "AXStandardWindow"` allowlist was the bug: yabai
    /// reports `subrole == ""` for real windows (Safari most visibly), so those
    /// windows were dropped — `windowsForApp` saw none and jump reopened a NEW
    /// window instead of focusing. Classification is now driven by `is-sticky`,
    /// yabai's stable, computed flag: the ChatGPT/Codex overlays that motivated
    /// the filter are always sticky (they follow you across every Space), and
    /// no real document window is. That primary signal catches even a Codex
    /// overlay reporting a brand-new subrole. `subrole` is used only as a
    /// denylist for the two explicit dialog values (a non-sticky app popup like
    /// a Safari dialog); as a denylist an empty subrole never matches, so real
    /// windows always pass — the opposite of the old allowlist. Tooltips carry
    /// role `AXHelpTag`. Note `is-floating` is NOT excluded: yabai floats some
    /// real app windows (System Settings), and excluding them would reopen.
    var isStandardWindow: Bool {
        hasAXReference
            && role != "AXHelpTag"
            && !isSticky
            && subrole != "AXDialog"
            && subrole != "AXSystemDialog"
    }

    /// A window that would be a standard jump target except yabai holds no
    /// AX reference for it. ChatGPT's Chromium build materializes its main
    /// window in the AX tree only while frontmost, so yabai can miss the
    /// reference entirely (empty role/subrole, unmanageable, unfocusable via
    /// yabai). Such a window can't be focused directly, but its Space is
    /// known and native activation reaches it.
    var isAXlessCandidate: Bool {
        !hasAXReference
            && role != "AXHelpTag"
            && !isSticky
            && subrole != "AXDialog"
            && subrole != "AXSystemDialog"
    }

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
        let isSticky = dict["is-sticky"] as? Int == 1
            || dict["is-sticky"] as? Bool == true
        let isFloating = dict["is-floating"] as? Int == 1
            || dict["is-floating"] as? Bool == true
        let hasFocus = dict["has-focus"] as? Int == 1
            || dict["has-focus"] as? Bool == true
        let isVisible = dict["is-visible"] as? Int == 1
            || dict["is-visible"] as? Bool == true
        return WindowInfo(id: id, appName: app, space: space,
                          isMinimized: isMinimized, role: role,
                          title: title, hasAXReference: hasAXRef,
                          subrole: subrole, isSticky: isSticky,
                          isFloating: isFloating, hasFocus: hasFocus,
                          isVisible: isVisible)
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

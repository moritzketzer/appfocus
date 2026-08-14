// Tests/Unit/WindowModelTests.swift
import Foundation
import Testing

private func win(_ id: Int, app: String = "Safari", space: Int = 1,
                 hasFocus: Bool = false, sticky: Bool = false) -> WindowInfo {
    WindowInfo(id: id, appName: app, space: space,
               isMinimized: false, role: "AXWindow", title: "window \(id)",
               hasAXReference: true, subrole: "AXStandardWindow",
               isSticky: sticky, isFloating: sticky, hasFocus: hasFocus)
}

@Suite("WindowModel")
struct WindowModelTests {

    @Test func parsesHasFocusFromYabaiDict() {
        let dict: [String: Any] = [
            "id": 42, "app": "Safari", "space": 3, "title": "t",
            "role": "AXWindow", "subrole": "AXStandardWindow",
            "is-minimized": false, "has-ax-reference": true,
            "is-sticky": false, "is-floating": false, "has-focus": true,
        ]
        let info = WindowInfo.from(yabaiDict: dict)
        #expect(info?.hasFocus == true)
    }

    @Test func hasFocusDefaultsToFalseWhenAbsent() {
        let dict: [String: Any] = [
            "id": 42, "app": "Safari", "space": 3, "title": "t",
            "role": "AXWindow",
        ]
        #expect(WindowInfo.from(yabaiDict: dict)?.hasFocus == false)
    }
}

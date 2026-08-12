// Tests/Unit/WindowInfoTests.swift
import Foundation
import Testing

@Suite("WindowInfo")
struct WindowInfoTests {

    /// Build a yabai-shaped window dict. yabai reports `role` as `AXWindow`
    /// for real windows AND dialogs alike; `subrole` is the discriminator.
    private func dict(id: Int, subrole: String, role: String = "AXWindow",
                      hasAXRef: Bool = true) -> [String: Any] {
        ["id": id, "app": "ChatGPT", "space": 1, "title": "Codex",
         "role": role, "subrole": subrole,
         "has-ax-reference": hasAXRef, "is-minimized": false]
    }

    @Test("a standard window is eligible")
    func standardWindowIsEligible() {
        let w = WindowInfo.from(yabaiDict: dict(id: 786, subrole: "AXStandardWindow"))
        #expect(w?.isStandardWindow == true)
    }

    @Test("a sticky AXDialog overlay is not eligible")
    func dialogIsNotEligible() {
        let w = WindowInfo.from(yabaiDict: dict(id: 793, subrole: "AXDialog"))
        #expect(w?.isStandardWindow == false)
    }

    @Test("an AXSystemDialog overlay is not eligible")
    func systemDialogIsNotEligible() {
        let w = WindowInfo.from(yabaiDict: dict(id: 5341, subrole: "AXSystemDialog"))
        #expect(w?.isStandardWindow == false)
    }

    @Test("a window without an AX reference is not eligible")
    func windowWithoutAXReferenceIsNotEligible() {
        let w = WindowInfo.from(yabaiDict: dict(id: 1, subrole: "AXStandardWindow",
                                                hasAXRef: false))
        #expect(w?.isStandardWindow == false)
    }

    @Test("subrole is parsed from the yabai dict")
    func subroleIsParsed() {
        let w = WindowInfo.from(yabaiDict: dict(id: 793, subrole: "AXDialog"))
        #expect(w?.subrole == "AXDialog")
    }

    @Test("a missing subrole defaults to empty and is not eligible")
    func missingSubroleIsNotEligible() {
        var d = dict(id: 2, subrole: "")
        d.removeValue(forKey: "subrole")
        let w = WindowInfo.from(yabaiDict: d)
        #expect(w?.subrole == "")
        #expect(w?.isStandardWindow == false)
    }
}

// Tests/Unit/WindowInfoTests.swift
import Foundation
import Testing

@Suite("WindowInfo")
struct WindowInfoTests {

    /// Build a yabai-shaped window dict. Real vs overlay is classified by the
    /// stable `is-sticky`/`is-floating` flags — NOT the AX `subrole`
    /// passthrough, which yabai reports empty for real windows (Safari most
    /// visibly).
    private func dict(id: Int, subrole: String, role: String = "AXWindow",
                      hasAXRef: Bool = true,
                      sticky: Bool = false, floating: Bool = false) -> [String: Any] {
        ["id": id, "app": "ChatGPT", "space": 1, "title": "Codex",
         "role": role, "subrole": subrole,
         "has-ax-reference": hasAXRef, "is-minimized": false,
         "is-sticky": sticky, "is-floating": floating]
    }

    @Test("a standard window is eligible")
    func standardWindowIsEligible() {
        let w = WindowInfo.from(yabaiDict: dict(id: 786, subrole: "AXStandardWindow"))
        #expect(w?.isStandardWindow == true)
    }

    @Test("a real window with an empty subrole is eligible (Safari reports subrole empty)")
    func emptySubroleRealWindowIsEligible() {
        // yabai routinely reports subrole="" for real Safari windows. The old
        // `subrole == "AXStandardWindow"` allowlist wrongly dropped these, so
        // jump saw no windows and reopened a NEW one. A non-sticky, non-floating
        // AXWindow is a real window regardless of subrole.
        let w = WindowInfo.from(yabaiDict: dict(id: 25681, subrole: ""))
        #expect(w?.subrole == "")
        #expect(w?.isStandardWindow == true)
    }

    @Test("a sticky + floating overlay is not eligible even with a standard subrole")
    func stickyFloatingOverlayIsNotEligible() {
        // ChatGPT/Codex overlays are sticky + floating. Classification must come
        // from those stable flags, not the subrole (which can even read
        // AXStandardWindow while the window is an overlay).
        let w = WindowInfo.from(yabaiDict: dict(id: 793, subrole: "AXStandardWindow",
                                                sticky: true, floating: true))
        #expect(w?.isStandardWindow == false)
    }

    @Test("a floating dialog is not eligible")
    func floatingDialogIsNotEligible() {
        // A real app dialog (e.g. a Safari popup) is floating but not sticky;
        // its explicit AXDialog subrole excludes it.
        let w = WindowInfo.from(yabaiDict: dict(id: 25640, subrole: "AXDialog",
                                                floating: true))
        #expect(w?.isStandardWindow == false)
    }

    @Test("a floating but non-sticky real window is eligible (System Settings)")
    func floatingStandardWindowIsEligible() {
        // yabai floats some real app windows (System Settings). They are NOT
        // overlays — not sticky, standard subrole — so floating alone must not
        // exclude them, or jump would reopen instead of focusing.
        let w = WindowInfo.from(yabaiDict: dict(id: 4210, subrole: "AXStandardWindow",
                                                sticky: false, floating: true))
        #expect(w?.isStandardWindow == true)
    }

    @Test("a tooltip (AXHelpTag) is not eligible")
    func helpTagGhostIsNotEligible() {
        let w = WindowInfo.from(yabaiDict: dict(id: 99, subrole: "AXUnknown",
                                                role: "AXHelpTag"))
        #expect(w?.isStandardWindow == false)
    }

    @Test("a window without an AX reference is not eligible")
    func windowWithoutAXReferenceIsNotEligible() {
        let w = WindowInfo.from(yabaiDict: dict(id: 1, subrole: "AXStandardWindow",
                                                hasAXRef: false))
        #expect(w?.isStandardWindow == false)
    }

    @Test("subrole and sticky/floating are parsed from the yabai dict")
    func fieldsAreParsed() {
        let w = WindowInfo.from(yabaiDict: dict(id: 793, subrole: "AXDialog",
                                                sticky: true, floating: true))
        #expect(w?.subrole == "AXDialog")
        #expect(w?.isSticky == true)
        #expect(w?.isFloating == true)
    }
}

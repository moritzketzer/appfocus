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

    @Test("an AX-less window with no overlay marker is an AX-less candidate")
    func axlessWindowWithoutOverlayMarkerIsCandidate() {
        // ChatGPT's Chromium window exists but yabai holds no AX reference for
        // it: not focusable through yabai, yet reachable by native activation.
        // An overlay missing the same reference must NOT qualify, or a jump
        // would "succeed" onto a sticky palette.
        let candidate = WindowInfo.from(yabaiDict: dict(id: 7, subrole: "",
                                                        hasAXRef: false))
        #expect(candidate?.isStandardWindow == false)
        #expect(candidate?.isAXlessCandidate == true)

        let sticky = WindowInfo.from(yabaiDict: dict(id: 8, subrole: "",
                                                     hasAXRef: false,
                                                     sticky: true))
        #expect(sticky?.isAXlessCandidate == false)

        let dialog = WindowInfo.from(yabaiDict: dict(id: 9, subrole: "AXDialog",
                                                     hasAXRef: false))
        #expect(dialog?.isAXlessCandidate == false)
    }

    @Test("subrole and sticky/floating are parsed from the yabai dict")
    func fieldsAreParsed() {
        let w = WindowInfo.from(yabaiDict: dict(id: 793, subrole: "AXDialog",
                                                sticky: true, floating: true))
        #expect(w?.subrole == "AXDialog")
        #expect(w?.isSticky == true)
        #expect(w?.isFloating == true)
    }

    @Test("numeric flags parse the same as boolean flags")
    func numericFlagsParseLikeBooleanFlags() {
        // JSONSerialization can surface yabai's flags as numbers instead of
        // booleans. Reading a numeric 1 as false would make every window
        // non-standard, so jump would reopen instead of focusing.
        let numeric = WindowInfo.from(yabaiDict: [
            "id": 42, "app": "Safari", "space": 3, "title": "Tabs",
            "role": "AXWindow", "subrole": "",
            "has-ax-reference": 1, "is-minimized": 0,
            "is-sticky": 1, "is-floating": 0,
            "has-focus": 1, "is-visible": 0])
        let boolean = WindowInfo.from(yabaiDict: [
            "id": 42, "app": "Safari", "space": 3, "title": "Tabs",
            "role": "AXWindow", "subrole": "",
            "has-ax-reference": true, "is-minimized": false,
            "is-sticky": true, "is-floating": false,
            "has-focus": true, "is-visible": false])
        #expect(numeric?.hasAXReference == true)
        #expect(numeric?.isMinimized == false)
        #expect(numeric?.isSticky == true)
        #expect(numeric?.isFloating == false)
        #expect(numeric?.hasFocus == true)
        #expect(numeric?.isVisible == false)
        #expect(numeric?.isStandardWindow == boolean?.isStandardWindow)
        #expect(numeric?.isAXlessCandidate == boolean?.isAXlessCandidate)
    }
}

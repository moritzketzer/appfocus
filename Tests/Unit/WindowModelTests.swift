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

    @Test func replaceSnapshotDerivesFocusedIdFromHasFocus() {
        let store = WindowModelStore()
        store.replaceSnapshot([win(1), win(2, hasFocus: true)])
        let m = store.snapshot()
        #expect(m.focusedId == 2)
        #expect(m.windows.count == 2)
        #expect(store.focusedWindow?.id == 2)
    }

    @Test func replaceSnapshotWithNoFocusedWindowYieldsNil() {
        let store = WindowModelStore()
        store.replaceSnapshot([win(1)])
        #expect(store.snapshot().focusedId == nil)
    }

    @Test func noteFocusedOverridesSnapshotFocus() {
        let store = WindowModelStore()
        store.replaceSnapshot([win(1, hasFocus: true), win(2)])
        store.noteFocused(id: 2)
        #expect(store.focusedWindow?.id == 2)
    }

    @Test func generationBumpsOnEveryRebuild() {
        let store = WindowModelStore()
        let g0 = store.snapshot().generation
        store.replaceSnapshot([win(1)])
        #expect(store.snapshot().generation == g0 + 1)
    }

    // MARK: - Straddle fences (rapid switching vs. slow snapshot queries)

    @Test func snapshotStartedBeforeOptimisticUpdateDoesNotRollBackFocus() {
        // The poller's query takes 90-350ms; a keypress lands mid-flight and
        // commits an optimistic focus. The stale dump (has-focus captured
        // pre-switch) must NOT roll focusedId back — that made the next press
        // a wrong "already focused" no-op or a spurious focusSpace.
        let store = WindowModelStore()
        store.replaceSnapshot([win(1, hasFocus: true), win(2)])
        let queryStart = DispatchTime.now()
        store.noteFocused(id: 2)                       // press lands after query start
        store.replaceSnapshot([win(1, hasFocus: true), win(2)],
                              queryStartedAt: queryStart)
        #expect(store.focusedWindow?.id == 2)
    }

    @Test func snapshotStartedAfterOptimisticUpdateWinsFocus() {
        // A query started after the last optimistic update reflects newer
        // truth (e.g. the user clicked elsewhere) — it must win.
        let store = WindowModelStore()
        store.noteFocused(id: 2)
        let queryStart = DispatchTime.now()
        store.replaceSnapshot([win(1, hasFocus: true), win(2)],
                              queryStartedAt: queryStart)
        #expect(store.focusedWindow?.id == 1)
    }

    @Test func dumpWithoutFocusRowKeepsPriorFocusedWindowIfStillPresent() {
        // Mid-Space-transition dumps briefly report NO has-focus row at all.
        // Wiping focusedId then made cycle report "no focused window" and
        // jump take a spurious cross-Space path. Keep the prior focus while
        // its window still exists in the snapshot.
        let store = WindowModelStore()
        store.replaceSnapshot([win(1, hasFocus: true), win(2)])
        store.replaceSnapshot([win(1), win(2)],
                              queryStartedAt: DispatchTime.now())
        #expect(store.focusedWindow?.id == 1)
    }

    @Test func dumpWithoutFocusRowClearsFocusWhenWindowGone() {
        let store = WindowModelStore()
        store.replaceSnapshot([win(1, hasFocus: true)])
        store.replaceSnapshot([win(2)],
                              queryStartedAt: DispatchTime.now())
        #expect(store.snapshot().focusedId == nil)
    }
}

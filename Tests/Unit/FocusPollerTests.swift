// Tests/Unit/FocusPollerTests.swift
import Foundation
import Testing

private func win(_ id: Int, app: String = "Safari", space: Int = 1,
                 sticky: Bool = false, subrole: String = "AXStandardWindow",
                 hasFocus: Bool = false) -> WindowInfo {
    WindowInfo(id: id, appName: app, space: space,
               isMinimized: false, role: "AXWindow", title: "w\(id)",
               hasAXReference: true, subrole: subrole,
               isSticky: sticky, isFloating: sticky, hasFocus: hasFocus)
}

@Suite("FocusPoller")
struct FocusPollerTests {

    private func makePoller() -> (MockWindowBackend, StateStore, WindowModelStore, FocusPoller) {
        let backend = MockWindowBackend()
        let store = StateStore(stateDir: NSTemporaryDirectory() + "appfocus-poll-\(UUID().uuidString)")
        let model = WindowModelStore()
        let config = AppFocusConfig(
            backend: "yabai", yabaiPath: "/usr/bin/true",
            aliases: ["Code": "Visual Studio Code"],
            reopenStrategies: [:], bundleIdentifiers: [:],
            pollIntervalMs: 2000)
        let poller = FocusPoller(backend: backend, store: store,
                                 config: config, model: model)
        return (backend, store, model, poller)
    }

    @Test func pollRebuildsModelAndRecordsMru() {
        let (backend, store, model, poller) = makePoller()
        backend.windows = [win(1), win(2, hasFocus: true)]

        poller.pollOnce()

        #expect(model.snapshot().windows.count == 2)
        #expect(model.focusedWindow?.id == 2)
        #expect(store.state(for: "Safari").lastFocusedId == 2)
    }

    @Test func pollDoesNotRecordFocusedStickyDialog() {
        let (backend, store, model, poller) = makePoller()
        backend.windows = [win(1),
                           win(9, sticky: true, subrole: "AXDialog", hasFocus: true)]

        poller.pollOnce()

        // The dialog IS the model's focused window (commands guard on it),
        // but it must never enter MRU state.
        #expect(model.snapshot().focusedId == 9)
        #expect(store.stateIfCached(for: "Safari")?.lastFocusedId == nil)
    }

    @Test func pollResolvesAliasWhenRecordingMru() {
        let (backend, store, _, poller) = makePoller()
        backend.windows = [win(3, app: "Code", hasFocus: true)]

        poller.pollOnce()

        #expect(store.state(for: "Visual Studio Code").lastFocusedId == 3)
    }

    @Test func failedQueryKeepsLastGoodModel() {
        let (backend, _, model, poller) = makePoller()
        backend.windows = [win(1, hasFocus: true)]
        poller.pollOnce()
        backend.queryAllWindowsFails = true   // transient yabai failure (nil)

        poller.pollOnce()

        #expect(model.snapshot().windows.count == 1)
        #expect(model.focusedWindow?.id == 1)
    }

    @Test func genuinelyEmptySnapshotWipesModel() {
        // A successful query returning zero windows is trustworthy: ghost
        // windows must leave the model, or jump keeps dead-ending on them
        // instead of taking the confirm/reopen path.
        let (backend, _, model, poller) = makePoller()
        backend.windows = [win(1, hasFocus: true)]
        poller.pollOnce()
        backend.windows = []   // desktop genuinely has zero windows

        poller.pollOnce()

        #expect(model.snapshot().windows.isEmpty)
        #expect(model.focusedWindow == nil)
    }
}

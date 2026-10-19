// Tests/Unit/StateStoreTests.swift
import Foundation
import Testing

@Suite("StateStore")
struct StateStoreTests {

    func makeTempStore() -> StateStore {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        return StateStore(stateDir: dir)
    }

    @Test func freshStateIsEmpty() {
        let store = makeTempStore()
        let state = store.state(for: "Safari")
        #expect(state.lastFocusedId == nil)
        #expect(state.ring.isEmpty)
    }

    @Test func recordFocusUpdatesState() {
        let store = makeTempStore()
        store.recordFocus(appName: "Safari", windowId: 1, space: 1)
        let state = store.state(for: "Safari")
        #expect(state.lastFocusedId == 1)
        #expect(state.lastFocusedSpace == 1)
    }

    @Test func recordFocusTracksPrevious() {
        let store = makeTempStore()
        store.recordFocus(appName: "Safari", windowId: 1)
        store.recordFocus(appName: "Safari", windowId: 2)
        let state = store.state(for: "Safari")
        #expect(state.lastFocusedId == 2)
        #expect(state.prevFocusedId == 1)
    }

    @Test func recordFocusSameWindowReturnsFalse() {
        let store = makeTempStore()
        store.recordFocus(appName: "Safari", windowId: 1)
        let changed = store.recordFocus(appName: "Safari", windowId: 1)
        #expect(changed == false)
    }

    @Test func separateAppsHaveSeparateState() {
        let store = makeTempStore()
        store.recordFocus(appName: "Safari", windowId: 1)
        store.recordFocus(appName: "Firefox", windowId: 2)
        #expect(store.state(for: "Safari").lastFocusedId == 1)
        #expect(store.state(for: "Firefox").lastFocusedId == 2)
    }

    @Test func globalLastFocusedApp() {
        let store = makeTempStore()
        store.recordFocus(appName: "Safari", windowId: 1)
        store.recordFocus(appName: "Firefox", windowId: 2)
        #expect(store.globalLastFocusedApp == "Firefox")
    }

    @Test func trackedAppCount() {
        let store = makeTempStore()
        #expect(store.trackedAppCount == 0)
        store.recordFocus(appName: "Safari", windowId: 1)
        store.recordFocus(appName: "Firefox", windowId: 2)
        #expect(store.trackedAppCount == 2)
    }

    @Test func updateMutatesState() {
        let store = makeTempStore()
        store.update(appName: "Safari") { state in
            state.ring = [1, 2, 3]
        }
        #expect(store.state(for: "Safari").ring == [1, 2, 3])
    }

    @Test func recordFocusSameWindowPreservesPrev() {
        let store = makeTempStore()
        store.recordFocus(appName: "Safari", windowId: 1)
        store.recordFocus(appName: "Safari", windowId: 2)
        // Re-focusing window 2 should be a no-op (returns false)
        // and must NOT overwrite prevFocusedId
        store.recordFocus(appName: "Safari", windowId: 2)
        let state = store.state(for: "Safari")
        #expect(state.prevFocusedId == 1)
        #expect(state.lastFocusedId == 2)
    }

    @Test func persistenceSurvivesReload() {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let store1 = StateStore(stateDir: dir)
        store1.recordFocus(appName: "Safari", windowId: 42, space: 2)
        store1.waitForPendingFlushesForTesting()

        // New store from same directory — should load from disk
        let store2 = StateStore(stateDir: dir)
        let state = store2.state(for: "Safari")
        #expect(state.lastFocusedId == 42)
        #expect(state.lastFocusedSpace == 2)
    }

    // Flushes are serialized in commit order, so the file ends up holding the
    // newest committed value. The old post-unlock flush let an earlier
    // writer's encode land last and persist state the store had already
    // superseded.
    @Test func diskKeepsTheNewestCommittedState() {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let store = StateStore(stateDir: dir)
        store.update(appName: "Safari") { $0.ring = [1, 2, 3] }
        store.update(appName: "Safari") { $0.ring = [4, 5, 6] }
        store.waitForPendingFlushesForTesting()

        let reloaded = StateStore(stateDir: dir)
        #expect(reloaded.state(for: "Safari").ring == [4, 5, 6])
    }
}

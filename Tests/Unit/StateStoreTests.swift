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
        store1.drainPendingFlushes()

        // New store from same directory — should load from disk
        let store2 = StateStore(stateDir: dir)
        let state = store2.state(for: "Safari")
        #expect(state.lastFocusedId == 42)
        #expect(state.lastFocusedSpace == 2)
    }

    // Pins the captured-value plumbing, not the old race: two updates from
    // one thread were ordered under the post-unlock flush too. What this does
    // catch is a flush that re-reads `states[appName]` instead of writing the
    // value it was handed, and a queue that loses the second write entirely.
    @Test func diskKeepsTheNewestCommittedState() {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let store = StateStore(stateDir: dir)
        store.update(appName: "Safari") { $0.ring = [1, 2, 3] }
        store.update(appName: "Safari") { $0.ring = [4, 5, 6] }
        store.drainPendingFlushes()

        let reloaded = StateStore(stateDir: dir)
        #expect(reloaded.state(for: "Safari").ring == [4, 5, 6])
    }

    // Four threads mutating ONE app, then one assertion: once every writer
    // joined, the file holds exactly what memory holds. Only that post-join
    // state is checked — never an intermediate order — so correct code is
    // deterministically green.
    //
    // One-sided, and measured as weak: against the reconstructed post-unlock
    // flush this stayed green over 18 runs (also at 16 writers × 50 updates),
    // and only went red once a randomized delay was injected between unlock
    // and write — disk 149 against memory 549, an inversion the assertion
    // does catch. So read a green run as no evidence about the race, and a red
    // one as proof the commit-order plumbing broke. What it pins in CI is that
    // concurrent writers cannot lose or cross the final write.
    @Test func concurrentWritersToOneAppAgreeWithDisk() {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let store = StateStore(stateDir: dir)

        // Dedicated threads, not `DispatchQueue.global()`: the deadline-driven
        // ActivationLogic tests run in parallel with this one and share that
        // pool, and four writers parked in it skewed their timing.
        let writers = DispatchGroup()
        for worker in 0..<4 {
            writers.enter()
            let writer = Thread {
                defer { writers.leave() }
                for i in 0..<25 {
                    // Distinguishable per writer and per iteration, so a stale
                    // write is a value no later commit could have produced.
                    let value = worker * 100 + i
                    store.update(appName: "Safari") {
                        $0.lastFocusedId = value
                        $0.ring = [value]
                    }
                }
            }
            writer.start()
        }
        writers.wait()
        store.drainPendingFlushes()

        let committed = store.state(for: "Safari")
        let reloaded = StateStore(stateDir: dir)
        let onDisk = reloaded.state(for: "Safari")
        #expect(onDisk.lastFocusedId == committed.lastFocusedId)
        #expect(onDisk.ring == committed.ring)
    }
}

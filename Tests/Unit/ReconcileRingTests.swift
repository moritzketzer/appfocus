// Tests/Unit/ReconcileRingTests.swift
import Testing

private func win(_ id: Int, space: Int = 1) -> WindowInfo {
    WindowInfo(id: id, appName: "App", space: space,
               isMinimized: false, role: "AXWindow", title: "",
               hasAXReference: true)
}

@Suite("Ring Reconciliation")
struct ReconcileRingTests {

    @Test func freshRingSortsBySpaceThenId() {
        let windows = [win(3, space: 2), win(1, space: 1), win(2, space: 1)]
        let ring = ActivationLogic.preserveRingOrder(prevRing: [], windows: windows)
        #expect(ring == [1, 2, 3])
    }

    @Test func existingRingPreservesOrder() {
        let windows = [win(1), win(2), win(3)]
        let ring = ActivationLogic.preserveRingOrder(prevRing: [3, 1, 2], windows: windows)
        #expect(ring == [3, 1, 2])
    }

    @Test func closedWindowsRemoved() {
        let windows = [win(1), win(3)]
        let ring = ActivationLogic.preserveRingOrder(prevRing: [3, 2, 1], windows: windows)
        #expect(ring == [3, 1])
    }

    @Test func newWindowsAppended() {
        let windows = [win(1), win(2), win(4)]
        let ring = ActivationLogic.preserveRingOrder(prevRing: [2, 1], windows: windows)
        #expect(ring == [2, 1, 4])
    }

    @Test func allPrevClosedGivesFreshRing() {
        let windows = [win(5, space: 2), win(4, space: 1)]
        let ring = ActivationLogic.preserveRingOrder(prevRing: [1, 2, 3], windows: windows)
        #expect(ring == [4, 5])
    }

    @Test func singleWindow() {
        let ring = ActivationLogic.preserveRingOrder(prevRing: [], windows: [win(42)])
        #expect(ring == [42])
    }

    @Test func emptyWindows() {
        let ring = ActivationLogic.preserveRingOrder(prevRing: [1, 2], windows: [])
        #expect(ring == [])
    }
}

// Tests/Unit/FocusPollerTests.swift
import Foundation
import Testing

/// Polls `condition` instead of sleeping a fixed duration, so timer-driven
/// assertions don't flake under machine load — where a fixed sleep can
/// under- or over-shoot how many ticks actually fired.
private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        usleep(10_000)
    }
}

@Suite("FocusPoller")
struct FocusPollerTests {

    @Test("does not fire a new poll while the previous one is still in flight")
    func singleFlightWhenBackendHangs() {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let config = AppFocusConfig(
            backend: "yabai", yabaiPath: "/usr/bin/true",
            aliases: [:], reopenStrategies: [:],
            pollIntervalMs: 100)
        let backend = MockWindowBackend()
        backend.focusedWindowHangs = true
        let store = StateStore(stateDir: dir)
        let poller = FocusPoller(backend: backend, store: store, config: config)

        poller.start()
        defer { poller.stop() }

        waitUntil(timeout: 5) { backend.focusedWindowCallCount >= 1 }
        #expect(backend.focusedWindowCallCount == 1, "expected the first poll to start")

        // Give many more tick intervals worth of time. Without the
        // single-flight guard, an unguarded timer stacks a new call on
        // top of every prior hung one — the exact mechanism that leaked
        // ~2553 stuck `yabai -m query` processes in production.
        usleep(600_000)
        #expect(backend.focusedWindowCallCount == 1,
                "expected exactly one in-flight poll, got \(backend.focusedWindowCallCount)")
    }

    @Test("resumes polling once the in-flight call completes")
    func resumesAfterInFlightCallCompletes() {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let config = AppFocusConfig(
            backend: "yabai", yabaiPath: "/usr/bin/true",
            aliases: [:], reopenStrategies: [:],
            pollIntervalMs: 100)
        let backend = MockWindowBackend()
        let store = StateStore(stateDir: dir)
        let poller = FocusPoller(backend: backend, store: store, config: config)

        poller.start()
        defer { poller.stop() }

        // Backend completes immediately here, so the guard must not
        // wedge polling shut — several ticks should still get through.
        waitUntil(timeout: 5) { backend.focusedWindowCallCount > 1 }
        #expect(backend.focusedWindowCallCount > 1,
                "expected polling to continue once each call completes")
    }

    @Test("a focused sticky dialog is never recorded into MRU state")
    func focusedDialogIsNotRecorded() {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let config = AppFocusConfig(
            backend: "yabai", yabaiPath: "/usr/bin/true",
            aliases: [:], reopenStrategies: [:],
            pollIntervalMs: 100)
        let backend = MockWindowBackend()
        // yabai reports a sticky Codex overlay as the focused window.
        backend.focusedWin = WindowInfo(
            id: 793, appName: "ChatGPT", space: 6, isMinimized: false,
            role: "AXWindow", title: "Codex", hasAXReference: true,
            subrole: "AXDialog", isSticky: true, isFloating: true)
        let store = StateStore(stateDir: dir)
        let poller = FocusPoller(backend: backend, store: store, config: config)

        poller.start()
        defer { poller.stop() }

        // Let several polls fire; each must skip the dialog.
        waitUntil(timeout: 5) { backend.focusedWindowCallCount >= 2 }

        // The dialog must never enter MRU state: no cached state, no
        // recorded lastFocusedId for the app.
        #expect(store.stateIfCached(for: "ChatGPT") == nil,
                "a dialog must not create tracked state for its app")
        #expect(store.state(for: "ChatGPT").lastFocusedId == nil,
                "a dialog must never become the app's last-focused window")
    }
}

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
}

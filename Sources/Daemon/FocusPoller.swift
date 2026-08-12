// Sources/Daemon/FocusPoller.swift
import Foundation

final class FocusPoller {
    private let backend: WindowBackend
    private let store: StateStore
    private let config: AppFocusConfig
    private var timer: DispatchSourceTimer?
    private let inFlightLock = NSLock()
    private var isPolling = false

    init(backend: WindowBackend, store: StateStore, config: AppFocusConfig) {
        self.backend = backend
        self.store = store
        self.config = config
    }

    func start() {
        let interval = DispatchTimeInterval.milliseconds(max(100, config.pollIntervalMs))
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        timer = t
        Log.info("Focus poller started (\(config.pollIntervalMs)ms interval)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        // Guard against overlapping polls: if the previous tick's `yabai`
        // call hasn't completed yet, skip this tick instead of stacking a
        // new concurrent call on top of it. Without this, a single slow or
        // hung call causes one new process to pile up every tick, forever.
        inFlightLock.lock()
        guard !isPolling else {
            inFlightLock.unlock()
            return
        }
        isPolling = true
        inFlightLock.unlock()

        backend.focusedWindow { [self] win in
            defer {
                self.inFlightLock.lock()
                self.isPolling = false
                self.inFlightLock.unlock()
            }
            guard let win = win else { return }
            // Never track a non-user-facing window (sticky/floating dialogs like
            // ChatGPT/Codex overlays). Recording one here is how a dialog would
            // enter MRU state and become a jump/cycle target.
            guard win.isStandardWindow else { return }
            let canonical = self.config.resolveAlias(win.appName)
            self.store.recordFocus(appName: canonical, windowId: win.id, space: win.space)
        }
    }
}

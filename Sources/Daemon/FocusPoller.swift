// Sources/Daemon/FocusPoller.swift
import Foundation

final class FocusPoller {
    private let backend: WindowBackend
    private let store: StateStore
    private let config: AppFocusConfig
    private var timer: DispatchSourceTimer?

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
        backend.focusedWindow { [self] win in
            guard let win = win else { return }
            let canonical = self.config.resolveAlias(win.appName)
            self.store.recordFocus(appName: canonical, windowId: win.id, space: win.space)
        }
    }
}

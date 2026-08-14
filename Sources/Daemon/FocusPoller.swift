// Sources/Daemon/FocusPoller.swift
import Foundation

/// Background bootstrap loop for the WindowModel: one full queryAllWindows
/// snapshot per tick rebuilds the model and records MRU focus state. This is
/// the ONLY steady-state yabai query in the daemon — commands read the model.
/// A stalled query delays the invisible refresh, never a keypress.
final class FocusPoller {
    private let backend: WindowBackend
    private let store: StateStore
    private let config: AppFocusConfig
    private let model: WindowModelStore
    private var timer: DispatchSourceTimer?
    private let inFlightLock = NSLock()
    private var isPolling = false

    init(backend: WindowBackend, store: StateStore, config: AppFocusConfig,
         model: WindowModelStore) {
        self.backend = backend
        self.store = store
        self.config = config
        self.model = model
    }

    func start() {
        let interval = DispatchTimeInterval.milliseconds(max(100, config.pollIntervalMs))
        let t = DispatchSource.makeTimerSource(queue: .global())
        // First tick immediately: commands issued right after daemon start
        // should find a populated model instead of paying the confirm query.
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        t.resume()
        timer = t
        Log.info("Snapshot poller started (\(config.pollIntervalMs)ms interval)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One poll tick. Internal (not private) so tests drive it directly
    /// without real timers. Guarded against overlap: a slow or hung query
    /// skips ticks instead of stacking concurrent yabai processes.
    func pollOnce() {
        inFlightLock.lock()
        guard !isPolling else {
            inFlightLock.unlock()
            return
        }
        isPolling = true
        inFlightLock.unlock()

        backend.queryAllWindows { [self] windows in
            defer {
                self.inFlightLock.lock()
                self.isPolling = false
                self.inFlightLock.unlock()
            }
            // A FAILED query (nil) keeps the last good model rather than
            // wiping it on a transient yabai stall. A genuinely empty dump
            // is trustworthy and must be accepted, or ghost windows stay in
            // the model forever once the desktop reaches zero windows.
            guard let windows = windows else { return }
            self.model.replaceSnapshot(windows)
            // Never track a non-user-facing window (sticky/floating dialogs
            // like ChatGPT/Codex overlays). Recording one here is how a
            // dialog would enter MRU state and become a jump/cycle target.
            guard let focused = windows.first(where: { $0.hasFocus }),
                  focused.isStandardWindow else { return }
            let canonical = self.config.resolveAlias(focused.appName)
            self.store.recordFocus(appName: canonical, windowId: focused.id,
                                   space: focused.space)
        }
    }
}

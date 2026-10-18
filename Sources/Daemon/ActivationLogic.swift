// Sources/Daemon/ActivationLogic.swift
import Foundation

final class ActivationLogic {
    private let config: AppFocusConfig
    private let backend: WindowBackend
    private let launcher: AppLauncher
    private let store: StateStore
    private let workspace: ApplicationWorkspace
    private let model: WindowModelStore
    private let pump: CommandPump

    init(config: AppFocusConfig, backend: WindowBackend,
         launcher: AppLauncher, store: StateStore,
         workspace: ApplicationWorkspace = SystemApplicationWorkspace(),
         model: WindowModelStore,
         verifier: OutcomeVerifying) {
        self.config = config
        self.backend = backend
        self.launcher = launcher
        self.store = store
        self.workspace = workspace
        self.model = model
        self.pump = CommandPump(verifier: verifier)
        pump.retryRunner = { [weak self] retry in
            self?.replayFocusRetry(retry)
        }
    }

    // MARK: - Command pump tunables and test hooks (delegated)

    var commandDeadline: TimeInterval {
        get { pump.commandDeadline }
        set { pump.commandDeadline = newValue }
    }
    var applicationDeadline: TimeInterval {
        get { pump.applicationDeadline }
        set { pump.applicationDeadline = newValue }
    }
    var hungBackoff: TimeInterval {
        get { pump.hungBackoff }
        set { pump.hungBackoff = newValue }
    }
    var maxPending: Int {
        get { pump.maxPending }
        set { pump.maxPending = newValue }
    }

    /// Test hook: synchronously fire the watchdog on the in-flight command,
    /// exercising the force-release path deterministically without waiting on
    /// the real GCD timer (which races under parallel test execution).
    func fireWatchdogNowForTesting(
        onRetryConsumed: (() -> Void)? = nil
    ) {
        pump.fireWatchdogNowForTesting(onRetryConsumed: onRetryConsumed)
    }

    /// Test hook: the pump holds no in-flight or queued command. The core
    /// resilience invariant is that this becomes true again after any command
    /// sequence drains — the pump is never left permanently wedged.
    var isIdleForTesting: Bool { pump.isIdleForTesting }

    private func isActive(_ token: UInt64) -> Bool {
        return pump.isActive(token)
    }

    /// Re-validate the target against the current model and replay ONLY the
    /// focus action. The replayed focus runs with armRetry=false so its own
    /// watchdog drop cannot re-arm. Called by the pump inside the transition
    /// that consumed the armed retry.
    private func replayFocusRetry(_ retry: CommandPump.RetryTarget) {
        let trace = CommandTrace(command: "jump", app: retry.appName)
        trace.update { $0.path = "retry" }
        pump.submit(domain: .window, app: retry.appName, trace: trace,
                    userInitiated: false) { [self] token, done in
            let windows = self.model.snapshot().windows
            guard let target = windows.first(where: { $0.id == retry.windowId }),
                  target.isStandardWindow, !target.isMinimized else {
                Log.info("retry: window \(retry.windowId) gone, dropping")
                trace.update {
                    $0.outcome = "noop"
                    $0.detail = "retry target gone"
                }
                done(); return
            }
            Log.info("retry: replaying focus for window \(target.id)")
            // focusSpace is issued unconditionally now; the model's focused
            // window only labels the trace's same/cross stats split.
            self.focusWindow(target, from: self.model.focusedWindow,
                             trace: trace, token: token, armRetry: false,
                             done: done)
        }
    }

    /// The repeated terminal exit of a decision that cannot act: classify the
    /// trace as failed and release the pump.
    private func failTrace(_ trace: CommandTrace, _ detail: String,
                           done: () -> Void) {
        trace.update {
            $0.outcome = "failed"
            $0.detail = detail
        }
        done()
    }

    // MARK: - Alias filtering

    private func windowsForApp(_ appName: String, from allWindows: [WindowInfo]) -> [WindowInfo] {
        allWindows.filter { config.resolveAlias($0.appName) == appName
                            && !$0.isMinimized && $0.isStandardWindow }
    }

    // MARK: - Jump

    func jump(appName rawName: String) {
        let appName = config.resolveAlias(rawName)
        let trace = CommandTrace(command: "jump", app: appName)
        let bundleIdentifier = config.bundleIdentifier(for: appName)

        if !isFrontmost(appName: appName, bundleIdentifier: bundleIdentifier) {
            trace.update {
                $0.path = bundleIdentifier == nil
                    ? ApplicationActionPath.legacyName.rawValue
                    : ApplicationActionPath.nativeBundle.rawValue
                $0.verificationTargetKind = .application
                $0.targetBundleIdentifier = bundleIdentifier
                $0.decidedAt = .now()
            }
            pump.submit(domain: .application, app: appName,
                        trace: trace) { [self] token, done in
                self.activateApplication(
                    appName: appName, bundleIdentifier: bundleIdentifier,
                    trace: trace, token: token, done: done)
            }
            return
        }

        pump.submit(domain: .window, app: appName, trace: trace) { [self] token, done in
            self.performJump(appName: appName, trace: trace, token: token, done: done)
        }
    }

    /// Does the resolved target already hold the foreground? Bundle identity
    /// when one is configured, localized name otherwise.
    private func isFrontmost(appName: String,
                             bundleIdentifier: String?) -> Bool {
        let frontmost = workspace.frontmostApplication
        if let bundleIdentifier {
            return frontmost?.bundleIdentifier == bundleIdentifier
        }
        return frontmost?.localizedName.map(config.resolveAlias) == appName
    }

    /// The cross-app jump action: native activation, zero yabai calls.
    private func activateApplication(appName: String,
                                     bundleIdentifier: String?,
                                     trace: CommandTrace, token: UInt64,
                                     done: @escaping () -> Void) {
        Log.info("jump: activating \(appName)")
        launcher.activate(
            appName: appName,
            bundleIdentifier: bundleIdentifier
        ) { [self] result in
            guard isActive(token) else { done(); return }
            trace.update {
                $0.path = result.path.rawValue
                $0.actionedAt = .now()
                if !result.success {
                    $0.outcome = "failed"
                    $0.detail = result.detail
                }
            }
            done()
        }
    }

    private func performJump(appName: String, trace: CommandTrace,
                             token: UInt64, done: @escaping () -> Void) {
        Log.info("jump: \(appName)")
        // Read the model ONCE — no yabai round-trip on the hot path, and no
        // torn read across a concurrent poller rebuild. A stalled
        // WindowServer now only delays the background refresh, never a press.
        let snapshot = model.snapshot()
        let focused = snapshot.focusedId.flatMap { id in
            snapshot.windows.first(where: { $0.id == id })
        }

        // Record the pre-jump focused window only if it is a real window;
        // a focused sticky dialog must not pollute MRU state.
        if let focused = focused, focused.isStandardWindow {
            let canonical = config.resolveAlias(focused.appName)
            store.recordFocus(appName: canonical, windowId: focused.id,
                              space: focused.space)
        }

        let windows = windowsForApp(appName, from: snapshot.windows)
        trace.update {
            $0.modelGeneration = snapshot.generation
            $0.modelFocusedId = snapshot.focusedId
        }
        if windows.isEmpty {
            trace.update { $0.path = "confirm" }
            confirmNoWindows(appName: appName, focused: focused,
                             trace: trace, token: token, done: done)
        } else {
            trace.update { $0.path = "hot" }
            handleHasWindows(appName: appName, windows: windows,
                             focused: focused, trace: trace,
                             token: token, done: done)
        }
    }

    /// The one deliberately fresh read: a stale "no windows" would reopen a
    /// duplicate window (the Safari-reopen bug class), so this rare branch
    /// pays for a live query and feeds the result back into the model.
    private func confirmNoWindows(appName: String, focused: WindowInfo?,
                                  trace: CommandTrace,
                                  token: UInt64, done: @escaping () -> Void) {
        backend.queryAllWindows { [self] all in
            guard self.isActive(token) else { done(); return }
            guard let all = all else {
                // Query FAILED — indistinguishable from "no windows" only if
                // conflated, and acting on it would reopen a duplicate. Do
                // nothing; the press is lost, the next one retries.
                Log.error("jump: confirm query failed for \(appName), not reopening")
                self.failTrace(trace, "confirm query failed", done: done)
                return
            }
            self.model.replaceSnapshot(all)
            let windows = self.windowsForApp(appName, from: all)
            if windows.isEmpty {
                let axless = all.filter {
                    self.config.resolveAlias($0.appName) == appName
                        && !$0.isMinimized && $0.isAXlessCandidate
                }
                self.handleNoWindows(appName: appName,
                                     axlessCandidates: axless, trace: trace,
                                     token: token, done: done)
            } else {
                Log.info("jump: confirm found \(windows.count) window(s) for \(appName)")
                self.handleHasWindows(appName: appName, windows: windows,
                                      focused: focused, trace: trace,
                                      token: token, done: done)
            }
        }
    }

    private func handleNoWindows(appName: String,
                                 axlessCandidates: [WindowInfo],
                                 trace: CommandTrace,
                                 token: UInt64, done: @escaping () -> Void) {
        let bundleIdentifier = config.bundleIdentifier(for: appName)
        trace.update {
            $0.verificationTargetKind = .application
            $0.targetBundleIdentifier = bundleIdentifier
            $0.decidedAt = .now()
        }

        if !axlessCandidates.isEmpty {
            Log.error("jump: \(appName) has \(axlessCandidates.count) window(s) without AX reference — activating natively; tiling needs a warm yabai restart (see gotchas)")
            trace.update {
                $0.path = "native-axless"
            }
            launcher.activate(
                appName: appName,
                bundleIdentifier: bundleIdentifier
            ) { [self] result in
                self.completeApplicationAction(
                    result, trace: trace, token: token, done: done)
            }
            return
        }

        Log.info("jump: \(appName) frontmost without windows, reopening")
        trace.update { $0.path = "reopen" }
        launcher.reopen(
            appName: appName,
            strategy: config.reopenStrategy(for: appName)
        ) { [self] result in
            self.completeApplicationAction(
                result, trace: trace, token: token, done: done)
        }
    }

    private func completeApplicationAction(
        _ result: ApplicationActionResult,
        trace: CommandTrace,
        token: UInt64,
        done: @escaping () -> Void
    ) {
        guard isActive(token) else { done(); return }
        trace.update {
            $0.actionedAt = .now()
            if !result.success {
                $0.outcome = "failed"
                $0.detail = result.detail
            }
        }
        done()
    }

    private func handleHasWindows(appName: String, windows: [WindowInfo],
                                    focused: WindowInfo?, trace: CommandTrace,
                                    token: UInt64,
                                    done: @escaping () -> Void) {
        // Only treat the app as "already focused" (MRU toggle / cycle) when a
        // REAL window of it is focused. If a sticky dialog is focused, fall
        // through to focusBestWindow so the standard window stays reachable
        // (otherwise the single-real-window case hits mruToggleOrCycle's
        // count==1 no-op and the standard window becomes unreachable).
        if let focused = focused, focused.isStandardWindow,
           config.resolveAlias(focused.appName) == appName {
            mruToggleOrCycle(appName: appName, windows: windows,
                             focused: focused, trace: trace,
                             token: token, done: done)
        } else {
            focusBestWindow(appName: appName, windows: windows,
                            focused: focused, trace: trace,
                            token: token, done: done)
        }
    }

    private func mruToggleOrCycle(appName: String, windows: [WindowInfo],
                                   focused: WindowInfo, trace: CommandTrace,
                                   token: UInt64,
                                   done: @escaping () -> Void) {
        guard windows.count > 1 else {
            // Re-assert focus instead of no-oping. The model can claim the
            // app is focused while the world is mid-transition — observed
            // live: a superseded command's uncancellable `space --focus` was
            // still in flight, this branch no-oped the press, and the zombie
            // Space switch then carried the user AWAY (the 10% Space-1 dead
            // presses, 2026-08-16). Re-asserting is idempotent and
            // guarantees "jump X" always ENDS on X.
            // focusSpace is now issued unconditionally in focusWindow, so
            // the real `focused` is safe to pass — it only labels the
            // trace's same/cross stats split honestly.
            Log.info("jump: \(appName) already focused, single window — re-asserting")
            focusBestWindow(appName: appName, windows: windows,
                            focused: focused, trace: trace,
                            token: token, done: done)
            return
        }

        let state = store.state(for: appName)
        let windowIds = Set(windows.map { $0.id })

        if let prevId = state.prevFocusedId, windowIds.contains(prevId) {
            mruSwitch(appName: appName, to: prevId, windows: windows,
                      focused: focused, trace: trace,
                      token: token, done: done)
        } else {
            cycleFromMRUMiss(appName: appName, windows: windows, state: state,
                             focused: focused, trace: trace,
                             token: token, done: done)
        }
    }

    /// The double-jump toggle: switch back to the app's previously focused
    /// window.
    private func mruSwitch(appName: String, to prevId: Int,
                           windows: [WindowInfo], focused: WindowInfo,
                           trace: CommandTrace, token: UInt64,
                           done: @escaping () -> Void) {
        Log.info("jump: \(appName) MRU switch to window \(prevId)")
        store.recordFocus(appName: appName, windowId: prevId)
        if let target = windows.first(where: { $0.id == prevId }) {
            focusWindow(target, from: focused, trace: trace,
                        token: token, done: done)
        } else {
            failTrace(trace, "MRU target vanished from window set",
                      done: done)
        }
    }

    /// No previous window to toggle back to: advance the ring instead.
    private func cycleFromMRUMiss(appName: String, windows: [WindowInfo],
                                  state: AppState, focused: WindowInfo,
                                  trace: CommandTrace, token: UInt64,
                                  done: @escaping () -> Void) {
        Log.info("jump: \(appName) no prev window, cycling next")
        let effectiveId = state.lastFocusedId ?? focused.id
        cycleWithKnownState(appName: appName, windows: windows,
                            focusedId: effectiveId, direction: .next,
                            current: focused, trace: trace,
                            token: token, done: done)
    }

    private func focusBestWindow(appName: String, windows: [WindowInfo],
                                 focused: WindowInfo?, trace: CommandTrace,
                                 token: UInt64,
                                 done: @escaping () -> Void) {
        let state = store.state(for: appName)

        let target = state.lastFocusedId.flatMap { lastId in
            windows.first(where: { $0.id == lastId })
        } ?? windows.first

        guard let target = target else {
            Log.error("jump: no target window for \(appName)")
            failTrace(trace, "no target window", done: done)
            return
        }

        Log.info("jump: focusing window \(target.id) for \(appName)")
        focusWindow(target, from: focused, trace: trace,
                    token: token, done: done)
    }

    private func focusWindow(_ target: WindowInfo, from current: WindowInfo?,
                             trace: CommandTrace,
                             token: UInt64, armRetry: Bool = true,
                             done: @escaping () -> Void) {
        trace.update {
            $0.targetWindowId = target.id
            $0.targetSpace = target.space
            $0.decidedAt = .now()
        }
        if armRetry { armRetryTarget(target, token: token) }

        // ALWAYS issue the Space switch — the same-Space skip is gone. Three
        // separate live defects came from trusting the model's Space claim
        // (superseded-zombie dead press, re-assert invisible landing, and
        // the first-press invisible landing at 09:45:58 on 2026-08-16 where
        // a stale model skipped the switch and the press needed a re-press).
        // The skip saved one ~10-70ms subprocess call on same-Space presses;
        // focusSpace on the already-active Space errors harmlessly and the
        // chain continues to the window focus either way. Correctness over
        // a micro-optimization. `crossedSpace` still records the MODEL's
        // view for the stats' same/cross split.
        recordSpaceCrossing(from: current, to: target, trace: trace)
        switchSpace(for: target, trace: trace, token: token, done: done)
    }

    /// Record the in-flight command's resolved focus target: if the watchdog
    /// drops this command mid-action, the retry can replay exactly this focus.
    private func armRetryTarget(_ target: WindowInfo, token: UInt64) {
        let retry = CommandPump.RetryTarget(
            appName: config.resolveAlias(target.appName),
            windowId: target.id)
        pump.armRetryTarget(retry, token: token)
    }

    /// Label the trace with the MODEL's same/cross-Space view. Never gates
    /// the Space switch itself.
    private func recordSpaceCrossing(from current: WindowInfo?,
                                     to target: WindowInfo,
                                     trace: CommandTrace) {
        if let current, current.isStandardWindow,
           current.space == target.space {
            trace.update { $0.crossedSpace = false }
        } else {
            trace.update { $0.crossedSpace = true }
        }
    }

    /// The Space-switch step: issue it unconditionally, then hand off to the
    /// window-focus step regardless of its result.
    private func switchSpace(for target: WindowInfo, trace: CommandTrace,
                             token: UInt64, done: @escaping () -> Void) {
        Log.info("focus: switching to space \(target.space) for window \(target.id)")
        backend.focusSpace(index: target.space) { [self] success in
            guard isActive(token) else { done(); return }
            if !success {
                // yabai refuses to focus an already-focused Space, and a
                // stale model can make this call spurious — aborting here
                // made the press do nothing at all (observed live). Continue
                // to the window focus: if we were already on the target
                // Space it lands visibly; a genuine Space-focus failure
                // still sets AX focus and the next press retries fresher.
                // Info, not error: the always-issued re-assert Space switch
                // hits "already focused" on every healthy same-Space press;
                // genuine anomalies surface as `invisible` telemetry.
                Log.info("focus: yabai space focus for \(target.space) failed — continuing to window focus")
            }
            focusTargetWindow(target, trace: trace, token: token, done: done)
        }
    }

    /// The window-focus step: the action that actually moves AX focus.
    private func focusTargetWindow(_ target: WindowInfo, trace: CommandTrace,
                                   token: UInt64,
                                   done: @escaping () -> Void) {
        guard isActive(token) else { done(); return }
        backend.focusWindow(id: target.id) { success in
            trace.update { $0.actionedAt = .now() }
            if success {
                // Read-your-writes: the next queued command must see the
                // settled focus without a query, so bursts compound.
                // Deliberately NOT token-gated: the model records the
                // last-COMPLETED focus action. A superseded command's
                // late-landing success really did move OS focus, so the
                // unguarded write tracks reality better than a fenced
                // one would; any residual disagreement self-heals at the
                // next poll.
                self.model.noteFocused(id: target.id)
            } else {
                Log.error("focus: yabai focus failed for window \(target.id)")
                trace.update {
                    $0.outcome = "failed"
                    $0.detail = "yabai window focus failed"
                }
            }
            done()
        }
    }

    // MARK: - Next/Prev

    /// Cycle windows using pre-fetched state. No async calls.
    private func cycleWithKnownState(appName: String, windows: [WindowInfo],
                                      focusedId: Int, direction: CycleDirection,
                                      current: WindowInfo, trace: CommandTrace,
                                      token: UInt64,
                                      done: @escaping () -> Void) {
        guard isActive(token) else { done(); return }
        guard windows.count > 1 else {
            Log.info("cycle: only \(windows.count) window(s)")
            trace.update {
                $0.path = "noop"
                $0.outcome = "noop"
                $0.detail = "only \(windows.count) window(s)"
            }
            done(); return
        }

        store.update(appName: appName) { state in
            state.ring = Self.preserveRingOrder(prevRing: state.ring, windows: windows)
        }

        let ring = store.state(for: appName).ring
        guard ring.count > 1 else {
            trace.update {
                $0.path = "noop"
                $0.outcome = "noop"
                $0.detail = "ring too small"
            }
            done(); return
        }

        let currentIdx = ring.firstIndex(of: focusedId) ?? 0
        let step = direction == .next ? 1 : -1
        let nextIdx = (currentIdx + step + ring.count) % ring.count
        let nextId = ring[nextIdx]

        Log.info("cycle: \(currentIdx) -> \(nextIdx) of \(ring.count) (window \(nextId))")
        store.recordFocus(appName: appName, windowId: nextId)
        if let target = windows.first(where: { $0.id == nextId }) {
            focusWindow(target, from: current, trace: trace,
                        token: token, done: done)
        } else {
            failTrace(trace, "ring id \(nextId) not in window set", done: done)
        }
    }

    func cycle(direction: CycleDirection) {
        let trace = CommandTrace(command: direction.rawValue, app: nil)
        pump.submit(domain: .window, app: nil, trace: trace) { [self] token, done in
            Log.info("cycle: \(direction)")
            self.performCycle(direction: direction, trace: trace, token: token, done: done)
        }
    }

    private func performCycle(direction: CycleDirection, trace: CommandTrace,
                              token: UInt64,
                              done: @escaping () -> Void) {
        // One model read — no yabai queries, no torn read across a poller
        // rebuild. The pump has already settled the previous command's focus
        // into the model (optimistic update).
        let snapshot = model.snapshot()
        trace.update {
            $0.path = "hot"
            $0.modelGeneration = snapshot.generation
            $0.modelFocusedId = snapshot.focusedId
        }
        guard let focused = snapshot.focusedId.flatMap({ id in
            snapshot.windows.first(where: { $0.id == id })
        }) else {
            Log.error("cycle: no focused window")
            failTrace(trace, "no focused window in model", done: done)
            return
        }

        let appName = config.resolveAlias(focused.appName)
        let windows = windowsForApp(appName, from: snapshot.windows)
        cycleWithKnownState(appName: appName, windows: windows,
                            focusedId: focused.id, direction: direction,
                            current: focused, trace: trace,
                            token: token, done: done)
    }

    enum CycleDirection: String {
        case next, prev
    }

    // MARK: - Ring reconciliation

    static func preserveRingOrder(prevRing: [Int], windows: [WindowInfo]) -> [Int] {
        let currentIds = Set(windows.map { $0.id })

        // Keep existing ring entries that still exist
        var kept = prevRing.filter { currentIds.contains($0) }

        if kept.isEmpty {
            // Fresh ring: sort by space then ID
            return windows
                .sorted { ($0.space, $0.id) < ($1.space, $1.id) }
                .map { $0.id }
        }

        // Append new windows not already in ring
        let keptSet = Set(kept)
        for win in windows where !keptSet.contains(win.id) {
            kept.append(win.id)
        }
        return kept
    }
}

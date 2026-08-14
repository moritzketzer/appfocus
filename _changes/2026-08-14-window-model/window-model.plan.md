# Window Model Read/Act Split Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all yabai queries from the appfocus keypress hot path by reading an in-memory `WindowModel` that a background snapshot poll keeps fresh, and cut the yabairc signal fan-out that multiplies WindowServer load.

**Architecture:** A new `WindowModelStore` holds the last full window snapshot plus the focused-window id. `FocusPoller` becomes the bootstrap loop (one `queryAllWindows` every 2 s, rebuilds the model, records MRU). `ActivationLogic` reads the model and issues only focus actions; the sole fresh query left is a confirm on the "no windows for a running app" branch, because a stale empty read there reopens a duplicate window. Successful focus actions update the model optimistically (read-your-writes for burst compounding). A watchdog-dropped focus action retries once after backoff. Parallel track in nix-config: debounce the sketchybar/sync_borders/auto-focus signal actions.

**Tech Stack:** Swift (raw swiftc via Makefile, Swift Testing framework, GCD), POSIX sh for yabai config. Build: `make all`; test: `make test` (always the full suite; single-test runs unsupported).

**Worktree:** `/Users/moritz/para/0-System/appfocus/.worktrees/window-model`, branch `change/window-model`. All appfocus commits land here. nix-config work uses its own worktree (Task 11).

---

### Task 1: `hasFocus` on WindowInfo + unfiltered backend snapshot

**Files:**
- Modify: `Sources/Daemon/Types.swift`
- Modify: `Sources/Daemon/YabaiBackend.swift:39-41`
- Create: `Tests/Unit/WindowModelTests.swift`

- [x] **Step 1: Write the failing tests**

Create `Tests/Unit/WindowModelTests.swift`:

```swift
// Tests/Unit/WindowModelTests.swift
import Foundation
import Testing

private func win(_ id: Int, app: String = "Safari", space: Int = 1,
                 hasFocus: Bool = false, sticky: Bool = false) -> WindowInfo {
    WindowInfo(id: id, appName: app, space: space,
               isMinimized: false, role: "AXWindow", title: "window \(id)",
               hasAXReference: true, subrole: "AXStandardWindow",
               isSticky: sticky, isFloating: sticky, hasFocus: hasFocus)
}

@Suite("WindowModel")
struct WindowModelTests {

    @Test func parsesHasFocusFromYabaiDict() {
        let dict: [String: Any] = [
            "id": 42, "app": "Safari", "space": 3, "title": "t",
            "role": "AXWindow", "subrole": "AXStandardWindow",
            "is-minimized": false, "has-ax-reference": true,
            "is-sticky": false, "is-floating": false, "has-focus": true,
        ]
        let info = WindowInfo.from(yabaiDict: dict)
        #expect(info?.hasFocus == true)
    }

    @Test func hasFocusDefaultsToFalseWhenAbsent() {
        let dict: [String: Any] = [
            "id": 42, "app": "Safari", "space": 3, "title": "t",
            "role": "AXWindow",
        ]
        #expect(WindowInfo.from(yabaiDict: dict)?.hasFocus == false)
    }
}
```

- [x] **Step 2: Run tests, verify they fail**

Run: `make test 2>&1 | grep -E "WindowModel|error:"`
Expected: compile error — `WindowInfo` has no `hasFocus` member.

- [x] **Step 3: Implement**

In `Sources/Daemon/Types.swift`, add the field, init parameter (default `false`, keeping every existing call site source-compatible), and parse:

```swift
    let isSticky: Bool
    let isFloating: Bool
    /// yabai's has-focus flag from the snapshot. Only meaningful on windows
    /// parsed out of a full `queryAllWindows` dump; the model derives its
    /// focusedId from it.
    let hasFocus: Bool

    init(id: Int, appName: String, space: Int, isMinimized: Bool,
         role: String, title: String, hasAXReference: Bool,
         subrole: String = "AXStandardWindow",
         isSticky: Bool = false, isFloating: Bool = false,
         hasFocus: Bool = false) {
        ...
        self.hasFocus = hasFocus
    }
```

In `from(yabaiDict:)`:

```swift
        let hasFocus = dict["has-focus"] as? Int == 1
            || dict["has-focus"] as? Bool == true
        return WindowInfo(id: id, appName: app, space: space,
                          isMinimized: isMinimized, role: role,
                          title: title, hasAXReference: hasAXRef,
                          subrole: subrole, isSticky: isSticky,
                          isFloating: isFloating, hasFocus: hasFocus)
```

In `Sources/Daemon/YabaiBackend.swift` remove the backend-level filter so the
model sees every window (consumers re-filter with `isStandardWindow`):

```swift
            let windows = json.compactMap { WindowInfo.from(yabaiDict: $0) }
            completion(windows)
```

- [x] **Step 4: Run tests, verify pass**

Run: `make test 2>&1 | grep "Test run"`
Expected: PASS (all suites; the ghost/dialog tests still pass because `windowsForApp` filters).

- [x] **Step 5: Commit**

```bash
git add Sources/Daemon/Types.swift Sources/Daemon/YabaiBackend.swift Tests/Unit/WindowModelTests.swift
git commit -m "feat: ✨ parse has-focus into WindowInfo; backend returns unfiltered snapshot"
```

---

### Task 2: WindowModelStore

**Files:**
- Create: `Sources/Daemon/WindowModel.swift`
- Modify: `Tests/Unit/WindowModelTests.swift`

- [x] **Step 1: Write the failing tests** (append inside `WindowModelTests`)

```swift
    @Test func replaceSnapshotDerivesFocusedIdFromHasFocus() {
        let store = WindowModelStore()
        store.replaceSnapshot([win(1), win(2, hasFocus: true)])
        let m = store.snapshot()
        #expect(m.focusedId == 2)
        #expect(m.windows.count == 2)
        #expect(store.focusedWindow?.id == 2)
    }

    @Test func replaceSnapshotWithNoFocusedWindowYieldsNil() {
        let store = WindowModelStore()
        store.replaceSnapshot([win(1)])
        #expect(store.snapshot().focusedId == nil)
    }

    @Test func noteFocusedOverridesSnapshotFocus() {
        let store = WindowModelStore()
        store.replaceSnapshot([win(1, hasFocus: true), win(2)])
        store.noteFocused(id: 2)
        #expect(store.focusedWindow?.id == 2)
    }

    @Test func generationBumpsOnEveryRebuild() {
        let store = WindowModelStore()
        let g0 = store.snapshot().generation
        store.replaceSnapshot([win(1)])
        #expect(store.snapshot().generation == g0 + 1)
    }
```

- [x] **Step 2: Run tests, verify fail** — `make test`; expected compile error: `WindowModelStore` undefined.

- [x] **Step 3: Implement** — create `Sources/Daemon/WindowModel.swift`:

```swift
// Sources/Daemon/WindowModel.swift
import Foundation

/// The daemon's in-memory picture of the desktop: a materialized view over
/// yabai's window state, rebuilt by the background snapshot poll and patched
/// optimistically when appfocus itself commits a focus change. Commands read
/// this instead of querying yabai, which is what keeps keypresses fast while
/// the WindowServer (and therefore yabai's query path) is stalled.
struct WindowModel {
    var windows: [WindowInfo] = []
    var focusedId: Int? = nil
    var generation: UInt64 = 0
    var lastRefresh: DispatchTime = .now()
}

/// Thread-safe holder. Writers: FocusPoller (snapshot rebuild) and
/// ActivationLogic (optimistic focus update, confirm-query rebuild).
/// Readers: ActivationLogic's command hot path.
final class WindowModelStore {
    private let lock = NSLock()
    private var model = WindowModel()

    func snapshot() -> WindowModel {
        lock.lock(); defer { lock.unlock() }
        return model
    }

    /// Full rebuild from a fresh queryAllWindows dump. focusedId is derived
    /// from yabai's has-focus flag.
    func replaceSnapshot(_ windows: [WindowInfo]) {
        lock.lock(); defer { lock.unlock() }
        model.windows = windows
        model.focusedId = windows.first(where: { $0.hasFocus })?.id
        model.generation &+= 1
        model.lastRefresh = .now()
    }

    /// Optimistic read-your-writes update after appfocus committed a focus
    /// action: the next queued command must see the settled focus without a
    /// query, so serialized bursts compound one step per press.
    func noteFocused(id: Int) {
        lock.lock(); defer { lock.unlock() }
        model.focusedId = id
    }

    /// The model's focused window, if it is still present in the snapshot.
    var focusedWindow: WindowInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let id = model.focusedId else { return nil }
        return model.windows.first(where: { $0.id == id })
    }
}
```

- [x] **Step 4: Run tests, verify pass** — `make test`; expected: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/Daemon/WindowModel.swift Tests/Unit/WindowModelTests.swift
git commit -m "feat: ✨ add WindowModelStore — in-memory window snapshot + focus"
```

---

### Task 3: Mock support — query counting and deferred focus actions

**Files:**
- Modify: `Tests/Unit/Mocks.swift`

The hot-path tests need to prove `queryAllWindows` was NOT called, and the
burst tests need to hold a focus action in flight (the old tests held the
now-removed per-command `focusedWindow` query instead).

- [x] **Step 1: Rewrite `MockWindowBackend`** (full replacement of the class; `MockProcessChecker` and `MockAppLauncher` stay unchanged):

```swift
/// Mock window backend that returns preset data and records calls.
final class MockWindowBackend: WindowBackend, @unchecked Sendable {
    var windows: [WindowInfo] = []
    var focusedWin: WindowInfo? = nil
    var focusedWindowIds: [Int] = []
    var focusedSpaces: [Int] = []
    var focusCalls: [String] = []
    var focusSpaceCompletesImmediately = true
    var pendingFocusSpaceCompletions: [(Bool) -> Void] = []
    var focusWindowCompletesImmediately = true
    var pendingFocusWindowCompletions: [(Bool) -> Void] = []

    var queryAllWindowsCompletesImmediately = true
    var pendingQueryAllWindowsCompletions: [([WindowInfo]) -> Void] = []

    private let callCountLock = NSLock()
    private var _queryAllWindowsCallCount = 0
    var queryAllWindowsCallCount: Int {
        callCountLock.lock(); defer { callCountLock.unlock() }
        return _queryAllWindowsCallCount
    }

    func queryAllWindows(completion: @escaping ([WindowInfo]) -> Void) {
        callCountLock.lock()
        _queryAllWindowsCallCount += 1
        callCountLock.unlock()
        if queryAllWindowsCompletesImmediately {
            completion(windows)
        } else {
            pendingQueryAllWindowsCompletions.append(completion)
        }
    }

    @discardableResult
    func completeNextQueryAllWindows() -> Bool {
        guard !pendingQueryAllWindowsCompletions.isEmpty else { return false }
        pendingQueryAllWindowsCompletions.removeFirst()(windows)
        return true
    }

    func focusedWindow(completion: @escaping (WindowInfo?) -> Void) {
        completion(focusedWin)
    }

    func focusWindow(id: Int, completion: @escaping (Bool) -> Void) {
        focusedWindowIds.append(id)
        focusCalls.append("window:\(id)")
        if focusWindowCompletesImmediately {
            completion(true)
        } else {
            pendingFocusWindowCompletions.append(completion)
        }
    }

    func focusSpace(index: Int, completion: @escaping (Bool) -> Void) {
        focusedSpaces.append(index)
        focusCalls.append("space:\(index)")
        if focusSpaceCompletesImmediately {
            completion(true)
        } else {
            pendingFocusSpaceCompletions.append(completion)
        }
    }

    func completeNextFocusSpace(success: Bool = true) {
        pendingFocusSpaceCompletions.removeFirst()(success)
    }

    @discardableResult
    func completeNextFocusWindow(success: Bool = true) -> Bool {
        guard !pendingFocusWindowCompletions.isEmpty else { return false }
        pendingFocusWindowCompletions.removeFirst()(success)
        return true
    }
}
```

- [x] **Step 2: Build to surface the fallout** — `make test 2>&1 | grep error: | head -20`. Expected: `ActivationLogicTests.swift` errors on `focusedWindowCompletesImmediately`, `completeNextFocusedWindow`, `focusedWindowCallCount`, `focusWindowUpdatesFocusedWin`, `focusedWindowHangs`. That fallout is fixed in Tasks 4-7 (the logic and tests move to the model together). Do NOT commit yet — this task commits with Task 4.

---

### Task 4: ActivationLogic reads the model — jump paths

**Files:**
- Modify: `Sources/Daemon/ActivationLogic.swift`
- Modify: `Sources/Daemon/main.swift`
- Modify: `Tests/Unit/ActivationLogicTests.swift`

- [x] **Step 1: Adapt the Harness and add the new hot-path tests**

In `ActivationLogicTests.swift`, replace the `Harness` init/members and add a
`sync()` helper (the private `win(...)` helper additionally forwards
`hasFocus`):

```swift
private func win(_ id: Int, app: String = "Safari", space: Int = 1,
                 subrole: String = "AXStandardWindow",
                 sticky: Bool = false, floating: Bool = false,
                 hasFocus: Bool = false) -> WindowInfo {
    WindowInfo(id: id, appName: app, space: space,
               isMinimized: false, role: "AXWindow", title: "window \(id)",
               hasAXReference: true, subrole: subrole,
               isSticky: sticky, isFloating: floating, hasFocus: hasFocus)
}
```

```swift
private struct Harness: @unchecked Sendable {
    let backend: MockWindowBackend
    let launcher: MockAppLauncher
    let store: StateStore
    let model: WindowModelStore
    let processChecker: MockProcessChecker
    let logic: ActivationLogic

    init(aliases: [String: String] = [:],
         strategies: [String: ReopenStrategy] = [:]) {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let config = AppFocusConfig(
            backend: "yabai", yabaiPath: "/usr/bin/true",
            aliases: aliases, reopenStrategies: strategies,
            pollIntervalMs: 2000)
        backend = MockWindowBackend()
        launcher = MockAppLauncher()
        store = StateStore(stateDir: dir)
        model = WindowModelStore()
        processChecker = MockProcessChecker()
        processChecker.runningApps = ["Safari", "Visual Studio Code", "Other"]
        logic = ActivationLogic(config: config, backend: backend,
                                 launcher: launcher, store: store,
                                 processChecker: processChecker,
                                 model: model)
        logic.commandDeadline = 3600
    }

    /// Simulate one background poll tick: the model absorbs the backend's
    /// current windows, with focusedWin marked as the focused one.
    func sync() {
        var wins = backend.windows
        if let f = backend.focusedWin {
            wins.removeAll { $0.id == f.id }
            wins.append(WindowInfo(id: f.id, appName: f.appName, space: f.space,
                                   isMinimized: f.isMinimized, role: f.role,
                                   title: f.title,
                                   hasAXReference: f.hasAXReference,
                                   subrole: f.subrole, isSticky: f.isSticky,
                                   isFloating: f.isFloating, hasFocus: true))
        }
        model.replaceSnapshot(wins)
    }

    func settle(ms: UInt32 = 300_000) {
        usleep(ms)
    }
}
```

Add the driving hot-path tests:

```swift
    // MARK: - Query-free hot path

    @Test func jumpWithWindowsInModelIssuesNoQueries() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount == 0)
        #expect(h.backend.focusedWindowIds.contains(1))
    }

    @Test func jumpWithEmptyModelConfirmsOnceBeforeReopening() {
        // Model knows nothing, but yabai actually has windows: the confirm
        // query must find them and focus — never reopen a duplicate.
        let h = Harness()
        h.backend.windows = [win(1)]
        h.backend.focusedWin = nil
        // model NOT synced — stays empty

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount == 1)
        #expect(h.launcher.reopenedApps.isEmpty)
        #expect(h.backend.focusedWindowIds.contains(1))
    }

    @Test func jumpConfirmedNoWindowsReopens() {
        let h = Harness()
        h.processChecker.runningApps = ["Safari"]
        h.backend.windows = []
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount >= 1)
        #expect(h.launcher.reopenedApps.count == 1)
    }

    @Test func staleModelTargetGoneFromBackendFailsCleanly() {
        // Model believes window 5 exists; it is gone. The focus action fails
        // (mock returns success, but membership in the model is what the
        // logic checks) — the point is no crash and the pump advances.
        let h = Harness()
        h.backend.windows = [win(5)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()
        h.backend.windows = []  // window vanished after the last poll

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.logic.isIdleForTesting)
    }
```

- [x] **Step 2: Run to verify the new tests fail** — `make test 2>&1 | grep error: | head`. Expected: compile errors (`model:` parameter unknown).

- [x] **Step 3: Implement the model-read jump in `ActivationLogic.swift`**

Add the dependency:

```swift
    private let processChecker: ProcessChecker
    private let model: WindowModelStore

    init(config: AppFocusConfig, backend: WindowBackend,
         launcher: AppLauncher, store: StateStore,
         processChecker: ProcessChecker, model: WindowModelStore) {
        ...
        self.model = model
    }
```

Replace `performJump` and add the confirm step (deleting the old
`backend.focusedWindow` step 1):

```swift
    private func performJump(appName: String, token: UInt64,
                             done: @escaping () -> Void) {
        // Read the model — no yabai round-trip on the hot path.
        let focused = model.focusedWindow

        // Record the pre-jump focused window only if it is a real window;
        // a focused sticky dialog must not pollute MRU state.
        if let focused = focused, focused.isStandardWindow {
            let canonical = config.resolveAlias(focused.appName)
            store.recordFocus(appName: canonical, windowId: focused.id,
                              space: focused.space)
        }

        let windows = windowsForApp(appName, from: model.snapshot().windows)
        if windows.isEmpty {
            confirmNoWindows(appName: appName, focused: focused,
                             token: token, done: done)
        } else {
            handleHasWindows(appName: appName, windows: windows,
                             focused: focused, token: token, done: done)
        }
    }

    /// The one deliberately fresh read: a stale "no windows" would reopen a
    /// duplicate window (the Safari-reopen bug class), so this rare branch
    /// pays for a live query and feeds the result back into the model.
    private func confirmNoWindows(appName: String, focused: WindowInfo?,
                                  token: UInt64, done: @escaping () -> Void) {
        backend.queryAllWindows { [self] all in
            guard self.isActive(token) else { done(); return }
            self.model.replaceSnapshot(all)
            let windows = self.windowsForApp(appName, from: all)
            if windows.isEmpty {
                self.handleNoWindows(appName: appName, focused: focused,
                                     token: token, done: done)
            } else {
                Log.info("jump: confirm found \(windows.count) window(s) for \(appName)")
                self.handleHasWindows(appName: appName, windows: windows,
                                      focused: focused, token: token, done: done)
            }
        }
    }
```

In `focusWindow(_:from:token:done:)`, apply the optimistic update on success:

```swift
        let focusTarget = { [self] in
            guard isActive(token) else { done(); return }
            backend.focusWindow(id: target.id) { success in
                if success {
                    self.model.noteFocused(id: target.id)
                } else {
                    Log.error("focus: yabai focus failed for window \(target.id)")
                }
                done()
            }
        }
```

In `pollForWindow`, feed each poll's result into the model (replace the
`queryAllWindows` completion's first lines):

```swift
            self.backend.queryAllWindows { allWindows in
                self.model.replaceSnapshot(allWindows)
                let windows = self.windowsForApp(appName, from: allWindows)
```

Update `Sources/Daemon/main.swift` wiring:

```swift
let model = WindowModelStore()
let logic = ActivationLogic(config: config, backend: backend,
                             launcher: launcher, store: store,
                             processChecker: processChecker, model: model)
let poller = FocusPoller(backend: backend, store: store, config: config,
                          model: model)
```

(`FocusPoller`'s `model:` parameter lands in Task 6; add it there — for this
task keep the poller's old init call and only pass `model:` to
`ActivationLogic`.)

- [x] **Step 4: Fix remaining compile fallout mechanically** — every existing
test that seeds `backend.windows`/`focusedWin` gains `h.sync()` before the
command under test; tests using the removed deferral members are rewritten in
Task 5/7. Compile-only stubs are fine until then, but prefer doing Task 5
immediately.

- [x] **Step 5: Run, verify the four new tests pass** — `make test`.

- [x] **Step 6: Commit** (with the Task 3 mock rewrite)

```bash
git add Sources/Daemon/ActivationLogic.swift Sources/Daemon/main.swift Tests/Unit/Mocks.swift Tests/Unit/ActivationLogicTests.swift
git commit -m "feat: ✨ jump reads WindowModel — zero yabai queries on the hot path"
```

---

### Task 5: Cycle from the model + burst compounding via optimistic focus

**Files:**
- Modify: `Sources/Daemon/ActivationLogic.swift:446-470` (performCycle)
- Modify: `Tests/Unit/ActivationLogicTests.swift`

- [x] **Step 1: Write/rewrite the tests**

```swift
    @Test func cycleIssuesNoQueries() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(1)
        h.sync()
        h.store.update(appName: "Safari") { $0.ring = [1, 2] }

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount == 0)
        #expect(h.backend.focusedWindowIds.last == 2)
    }

    @Test func cycleWithNoFocusInModelLogsAndCompletes() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.sync()  // nothing focused

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
        #expect(h.logic.isIdleForTesting)
    }
```

Rewrite the two rapid tests to hold the focus ACTION in flight (the pump
serialization is unchanged; what compounds each press is now the optimistic
model update on each completed focus):

```swift
    @Test func rapidRepeatedCycleCommandsAreHandledInOrder() {
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(1)
        h.sync()
        h.backend.focusWindowCompletesImmediately = false
        h.store.update(appName: "Safari") { $0.ring = [1, 2, 3] }

        let presses = 12
        for _ in 0..<presses {
            h.logic.cycle(direction: .next)
        }

        for _ in 0..<presses {
            #expect(h.backend.completeNextFocusWindow())
            h.settle(ms: 20_000)
        }
        h.settle()

        // 12 presses from window 1 over ring [1,2,3]: every press must land,
        // in order, ending where a full 4x loop ends.
        #expect(h.backend.focusedWindowIds.count == presses)
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func rapidRepeatedJumpCommandsAreHandledInOrder() {
        let h = Harness()
        h.backend.windows = [win(1, app: "cmux"), win(2, app: "cmux")]
        h.backend.focusedWin = win(1, app: "cmux")
        h.sync()
        h.backend.focusWindowCompletesImmediately = false
        h.processChecker.runningApps.insert("cmux")
        h.store.update(appName: "cmux") { $0.ring = [1, 2] }

        let presses = 8
        for _ in 0..<presses {
            h.logic.jump(appName: "cmux")
        }

        for _ in 0..<presses {
            #expect(h.backend.completeNextFocusWindow())
            h.settle(ms: 20_000)
        }
        h.settle()

        #expect(h.backend.focusedWindowIds.count == presses)
        #expect(h.backend.focusedWindowIds.last == 1)
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }
```

- [x] **Step 2: Run, verify fail** — `make test`.

- [x] **Step 3: Implement `performCycle`**

```swift
    private func performCycle(direction: CycleDirection, token: UInt64,
                              done: @escaping () -> Void) {
        guard let focused = model.focusedWindow else {
            Log.error("cycle: no focused window")
            done(); return
        }

        let appName = config.resolveAlias(focused.appName)
        let windows = windowsForApp(appName, from: model.snapshot().windows)
        cycleWithKnownState(appName: appName, windows: windows,
                            focusedId: focused.id, direction: direction,
                            current: focused, token: token, done: done)
    }
```

- [x] **Step 4: Run, verify pass** — `make test` (rapid tests + new cycle tests green).

- [x] **Step 5: Commit**

```bash
git add Sources/Daemon/ActivationLogic.swift Tests/Unit/ActivationLogicTests.swift
git commit -m "feat: ✨ cycle reads WindowModel; bursts compound via optimistic focus"
```

---

### Task 6: FocusPoller becomes the snapshot bootstrap loop

**Files:**
- Modify: `Sources/Daemon/FocusPoller.swift`
- Modify: `Sources/Daemon/main.swift`
- Create: `Tests/Unit/FocusPollerTests.swift`

- [x] **Step 1: Write the failing tests**

```swift
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
            reopenStrategies: [:], pollIntervalMs: 2000)
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
}
```

- [x] **Step 2: Run, verify fail** — compile error: `FocusPoller` has no `model`/`pollOnce`.

- [x] **Step 3: Implement** — rewrite `FocusPoller`:

```swift
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
            guard !windows.isEmpty else { return }  // failed/empty query: keep the last good model
            self.model.replaceSnapshot(windows)
            // Never track a non-user-facing window (sticky/floating dialogs):
            // recording one here is how a dialog would enter MRU state.
            guard let focused = windows.first(where: { $0.hasFocus }),
                  focused.isStandardWindow else { return }
            let canonical = self.config.resolveAlias(focused.appName)
            self.store.recordFocus(appName: canonical, windowId: focused.id,
                                   space: focused.space)
        }
    }
}
```

Update `main.swift`'s poller construction to pass `model: model` (wired in
Task 4's snippet).

- [x] **Step 4: Run, verify pass** — `make test`.

- [x] **Step 5: Commit**

```bash
git add Sources/Daemon/FocusPoller.swift Sources/Daemon/main.swift Tests/Unit/FocusPollerTests.swift
git commit -m "feat: ✨ FocusPoller polls full snapshots into the WindowModel"
```

---

### Task 7: Adapt the remaining test suite to the model flow

**Files:**
- Modify: `Tests/Unit/ActivationLogicTests.swift`

- [x] **Step 1: Mechanical sweep** — every remaining test that seeds
`h.backend.windows` / `h.backend.focusedWin` and expects jump/cycle to see
them adds `h.sync()` after seeding (and after any mid-test reseed that the
old flow picked up via live queries — e.g. `cycleNextFullLoop` re-seeds
`focusedWin` between presses: replace each `h.backend.focusedWin = win(N)`
with that assignment plus `h.sync()`). Specific adaptations:

- `launchedWindowAcrossSpacesFocusesSpaceBeforeWindow`: no `sync()` (model
  cold is the point); the confirm query + launch + `pollForWindow` chain
  finds the windows seeded after `jump`.
- `queueCapBoundsBacklogUnderHammering`: seed + `sync()`, hold with
  `focusWindowCompletesImmediately = false`, drain with
  `completeNextFocusWindow()`, assert
  `h.backend.focusedWindowIds.count == 1 + h.logic.maxPending`.
- `watchdogReleasesPumpWhenAYabaiCallHangs`: seed + `sync()`, hold with
  `focusWindowCompletesImmediately = false`, fire watchdog, then set
  `focusWindowCompletesImmediately = true`, jump again, expect a landed
  focus (the second jump also clears the pending retry — deterministic).
- `newerJumpCancelsWindowFocusAfterOlderSpaceTransition`: seed windows for
  BOTH apps up front (`win(1, app: "Safari", space: 2)`,
  `win(2, app: "Code", space: 3)`), `sync()` once; the mid-test
  `h.backend.windows` reassignment disappears (the model is what the logic
  reads).
- Fuzz test `pumpStaysConsistentUnderRandomCommandSequences`: seed + `sync()`
  per iteration; `h.logic.hungBackoff = 0` so retries fire fast; hold with
  `focusWindowCompletesImmediately = false`; drain with
  `completeNextFocusWindow()`; after the watchdog fire, `h.settle(ms: 150_000)`
  then drain again (a one-shot retry may have queued another focus action),
  then assert idle + valid ids. The invariant gains: retries never wedge the
  pump.

```swift
            var guardN = 0
            while h.backend.completeNextFocusWindow() { guardN += 1; if guardN > 500 { break } }
            h.logic.fireWatchdogNowForTesting()
            h.settle(ms: 150_000)
            while h.backend.completeNextFocusWindow() { guardN += 1; if guardN > 1000 { break } }
            h.settle(ms: 50_000)

            #expect(h.logic.isIdleForTesting, "pump must return to idle, never wedge")
```

- [x] **Step 2: Full suite green ×2** — `make test` twice; expected: PASS both.

- [x] **Step 3: Commit**

```bash
git add Tests/Unit/ActivationLogicTests.swift
git commit -m "test: ✅ adapt suite to model-read flow (sync seeds, focus-action deferral)"
```

---

### Task 8: One-shot retry of a watchdog-dropped focus action

**Files:**
- Modify: `Sources/Daemon/ActivationLogic.swift`
- Modify: `Tests/Unit/ActivationLogicTests.swift`

- [x] **Step 1: Write the failing tests**

```swift
    // MARK: - One-shot retry after a watchdog drop

    @Test func watchdogDroppedFocusRetriesOnceAfterBackoff() {
        let h = Harness()
        h.logic.hungBackoff = 0.0
        h.backend.windows = [win(1, space: 2)]
        h.backend.focusedWin = win(99, app: "Other", space: 1)
        h.sync()
        h.backend.focusWindowCompletesImmediately = false

        h.logic.jump(appName: "Safari")   // resolves target 1, focus hangs
        h.settle(ms: 100_000)
        h.logic.fireWatchdogNowForTesting()
        h.settle()                         // backoff 0 + epsilon → retry fires

        // The retry replays the focus action for the SAME window once.
        #expect(h.backend.focusedWindowIds == [1, 1])

        while h.backend.completeNextFocusWindow() {}
        h.settle()
        #expect(h.logic.isIdleForTesting)
    }

    @Test func userCommandCancelsPendingRetry() {
        let h = Harness()
        h.logic.hungBackoff = 0.4
        h.backend.windows = [win(1)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()
        h.backend.focusWindowCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.settle(ms: 100_000)
        h.logic.fireWatchdogNowForTesting()
        // Press during the backoff window: the circuit breaker drops the
        // press, but it still expresses newer intent — the pending retry is
        // cancelled and must never replay.
        h.logic.jump(appName: "Safari")
        h.settle(ms: 700_000)   // past backoff (400ms) + retry epsilon (50ms)

        #expect(h.backend.focusedWindowIds == [1])   // no replay
        while h.backend.completeNextFocusWindow() {}
        h.settle()
        #expect(h.logic.isIdleForTesting)
    }

    @Test func noRetryWhenDroppedBeforeTargetResolved() {
        // Stuck in the confirm query — no focus target was resolved yet, so
        // nothing must replay (launch/reopen paths never auto-retry).
        let h = Harness()
        h.logic.hungBackoff = 0.0
        h.backend.windows = []
        h.backend.focusedWin = nil
        // model empty → confirm path; hold the confirm query in flight so the
        // watchdog drops the command before any focus target exists.
        h.backend.queryAllWindowsCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.settle(ms: 100_000)
        h.logic.fireWatchdogNowForTesting()
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
        #expect(h.logic.isIdleForTesting)
    }

    @Test func retryTargetGoneFromModelIsDropped() {
        let h = Harness()
        h.logic.hungBackoff = 0.0
        h.backend.windows = [win(1)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()
        h.backend.focusWindowCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.settle(ms: 100_000)
        h.model.replaceSnapshot([])       // window vanished before the retry
        h.logic.fireWatchdogNowForTesting()
        h.settle()

        #expect(h.backend.focusedWindowIds == [1])  // no replay
        #expect(h.logic.isIdleForTesting)
    }
```

- [x] **Step 2: Run, verify fail** — first test: `focusedWindowIds == [1]`, no retry.

- [x] **Step 3: Implement in `ActivationLogic.swift`**

State (near the pump state):

```swift
    // MARK: - One-shot retry of a watchdog-dropped focus action
    //
    // Observed: a cross-Space jump kept hitting the stall window and being
    // watchdog-dropped while quick same-Space toggles landed in the gaps, so
    // the user had to re-press. When the watchdog drops a command whose focus
    // TARGET was already resolved, replay just the focus action once after
    // the backoff. The decision logic is never replayed (an already-recorded
    // MRU toggle must not double-toggle), launch/reopen never retries, and
    // any newer user command cancels the pending retry.
    private struct RetryTarget {
        let appName: String?
        let windowId: Int
    }
    /// The in-flight command's resolved focus target (guarded by activationQueue).
    private var inFlightTarget: (token: UInt64, target: RetryTarget)?
    /// Armed by the watchdog, consumed (or cancelled) exactly once.
    private var pendingRetry: RetryTarget?
```

Clear on user commands (public entries):

```swift
    func jump(appName rawName: String) {
        let appName = config.resolveAlias(rawName)
        activationQueue.sync { pendingRetry = nil }
        submit(app: appName) { [self] token, done in
            Log.info("jump: \(appName)")
            self.performJump(appName: appName, token: token, done: done)
        }
    }

    func cycle(direction: CycleDirection) {
        activationQueue.sync { pendingRetry = nil }
        submit(app: nil) { [self] token, done in
            Log.info("cycle: \(direction)")
            self.performCycle(direction: direction, token: token, done: done)
        }
    }
```

`focusWindow` notes the resolved target (all existing callers pass
`armRetry: true` implicitly via the default; the retry path passes `false`).
The app name for resubmission comes from the target's alias-resolved app:

```swift
    private func focusWindow(_ target: WindowInfo, from current: WindowInfo?,
                             token: UInt64, armRetry: Bool = true,
                             done: @escaping () -> Void) {
        if armRetry {
            let retry = RetryTarget(appName: config.resolveAlias(target.appName),
                                    windowId: target.id)
            activationQueue.sync { inFlightTarget = (token, retry) }
        }
        ...
    }
```

`watchdogFire` arms the retry when the dropped token had a resolved target:

```swift
    private func watchdogFire(_ token: UInt64) {
        var fired = false
        var armed = false
        activationQueue.sync {
            guard token == currentToken, running else { return }
            currentToken &+= 1
            pending.removeAll()
            running = false
            runningApp = nil
            hungUntil = DispatchTime.now() + self.hungBackoff
            fired = true
            if let f = inFlightTarget, f.token == token {
                pendingRetry = f.target
                inFlightTarget = nil
                armed = true
            }
        }
        if fired {
            Log.error("pump: WATCHDOG tok=\(token) exceeded \(self.commandDeadline)s — yabai unresponsive; released + backing off \(self.hungBackoff)s")
        }
        if armed {
            // Fire just past the backoff window so the resubmission is not
            // dropped by the circuit breaker.
            DispatchQueue.global().asyncAfter(deadline: .now() + hungBackoff + 0.05) { [weak self] in
                self?.submitPendingRetry()
            }
        }
    }

    private func submitPendingRetry() {
        var retry: RetryTarget?
        activationQueue.sync {
            retry = pendingRetry
            pendingRetry = nil
        }
        guard let retry else { return }  // cancelled by a newer user command
        submit(app: retry.appName) { [self] token, done in
            // Re-validate against the current model; the world may have moved.
            let windows = self.model.snapshot().windows
            guard let target = windows.first(where: { $0.id == retry.windowId }),
                  target.isStandardWindow, !target.isMinimized else {
                Log.info("retry: window \(retry.windowId) gone, dropping")
                done(); return
            }
            Log.info("retry: replaying focus for window \(target.id)")
            self.focusWindow(target, from: self.model.focusedWindow,
                             token: token, armRetry: false, done: done)
        }
    }
```

- [x] **Step 4: Run, verify all retry tests + fuzz pass** — `make test` ×2.

- [x] **Step 5: Commit**

```bash
git add Sources/Daemon/ActivationLogic.swift Tests/Unit/ActivationLogicTests.swift
git commit -m "feat: ✨ one-shot retry lands a watchdog-dropped focus after recovery"
```

---

### Task 9: Config default 2000 ms

**Files:**
- Modify: `Sources/Daemon/Config.swift:28,73`
- Modify: `Tests/Unit/ConfigTests.swift` (check first: `grep -n 1000 Tests/Unit/ConfigTests.swift`)

- [x] **Step 1: Update any ConfigTests default-assertion to 2000** (write the failing expectation first if one exists; if none asserts the poll default, add one):

```swift
    @Test func pollIntervalDefaultsTo2000() {
        #expect(AppFocusConfig.default.pollIntervalMs == 2000)
    }
```

- [x] **Step 2: Implement** — `pollIntervalMs: 2000` in `default`, `?? 2000` in `decodeIfPresent`.

- [x] **Step 3: `make test` green. Commit:**

```bash
git add Sources/Daemon/Config.swift Tests/Unit/ConfigTests.swift
git commit -m "feat: ✨ default poll_interval_ms 2000 — full snapshots, not focus pings"
```

---

### Task 10: Documentation

**Files:**
- Modify: `CLAUDE.md` (project) — FocusPoller line in Project Structure, Architecture flow, config table (`poll_interval_ms | 2000 | Snapshot poll interval`).
- Modify: `~/.claude/skills/developing-appfocus/references/gotchas.md` — run `readlink -f` first; if it resolves into nix-config, make the edit part of Task 11's nix-config worktree instead. Append under "Focus / Switch" an architecture note: WindowModel read/act split (commands read the model; the only steady-state query is the 2 s snapshot poll; confirm query on the windowless branch; ≤2 s staleness accepted with the external-Space-switch race documented; one-shot retry semantics). Append under "Other" the test de-flake entry (fixture orphan poisoning + timer drift under fuzz load, fixed in `39e2b7d`).

- [x] **Step 1: Make both edits.**
- [x] **Step 2: Commit the CLAUDE.md edit in appfocus:**

```bash
git add CLAUDE.md
git commit -m "docs: 📝 document WindowModel read/act split + 2s snapshot poll"
```

---

### Task 11: nix-config — debounce the yabai signal fan-out

**Files (nix-config worktree `change/yabai-signal-debounce`):**
- Create: `darwin/home/config/yabai/debounce.sh`
- Create: `darwin/home/config/yabai/autofocus.sh`
- Modify: `darwin/home/config/yabai/yabairc:26-30,78-84,98-124`
- Possibly modify: the gotchas reference from Task 10.

- [x] **Step 1: Create the worktree** — in `~/para/0-System/nix-config`: `git wt-add yabai-signal-debounce && cd .worktrees/yabai-signal-debounce`.

- [x] **Step 2: Write `debounce.sh`** (trailing-edge coalescing; a burst of invocations runs the command once after the quiet gap):

```bash
#!/usr/bin/env bash
# debounce.sh <key> <delay_ms> <cmd> [args...]
# Trailing-edge debounce: each invocation stamps a token; only the invocation
# whose token is still newest after the delay runs the command. yabai fires
# signals per event, so a burst of window events would otherwise fan out into
# a burst of sketchybar redraws and yabai queries exactly while yabai is busy.
set -u
key="$1"; delay_ms="$2"; shift 2
dir="${TMPDIR:-/tmp}/yabai-debounce"
mkdir -p "$dir"
stamp="$dir/$key"
token="$(date +%s%N)"
printf '%s' "$token" > "$stamp"
(
  sleep "$(awk -v ms="$delay_ms" 'BEGIN{printf "%.3f", ms/1000}')"
  [ "$(cat "$stamp" 2>/dev/null)" = "$token" ] && exec "$@"
) &
```

- [x] **Step 3: Write `autofocus.sh`** (extracted from the two inline signal bodies; the debounce delay replaces the inline `sleep 0.1`/`0.2` settle):

```bash
#!/usr/bin/env bash
# autofocus.sh — after a window closes or an app quits, re-focus the top
# visible window on the current space if nothing has focus (fall back to the
# most recently focused window, which may be on another space).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
has_focus=$("$YABAI" -m query --windows --space | "$JQ" 'any(.[]; ."has-focus")')
[ "$has_focus" = "false" ] || exit 0
window_id=$("$YABAI" -m query --windows --space | "$JQ" -r '
  [.[] | select(."is-visible")] | sort_by(."stack-index") | .[0].id // empty')
if [ -n "$window_id" ] && [ "$window_id" != "null" ]; then
  "$YABAI" -m window --focus "$window_id"
else
  "$YABAI" -m window --focus recent 2>/dev/null
fi
```

- [x] **Step 4: Patch `yabairc`**

Add near the top (after `SYNC_BORDERS=` line): `DEBOUNCE="$SCRIPT_DIR/debounce.sh"`.

Replace lines 26-30 (per-event sketchybar triggers):

```sh
yabai -m signal --add event=window_focused        action="$DEBOUNCE sb-focus 200 $SKETCHYBAR --trigger window_focus"
yabai -m signal --add event=window_created        action="$DEBOUNCE sb-spaces 200 $SKETCHYBAR --trigger windows_on_spaces"
yabai -m signal --add event=window_destroyed      action="$DEBOUNCE sb-spaces 200 $SKETCHYBAR --trigger windows_on_spaces"
yabai -m signal --add event=application_launched   action="$DEBOUNCE sb-spaces 200 $SKETCHYBAR --trigger windows_on_spaces"
yabai -m signal --add event=application_terminated action="$DEBOUNCE sb-spaces 200 $SKETCHYBAR --trigger windows_on_spaces"
```

Replace the border-event loop's action (line 83): `action="$DEBOUNCE sync-borders 150 $SYNC_BORDERS"`.

Replace the two inline auto-focus signal bodies (lines 98-124) with:

```sh
yabai -m signal --add event=window_destroyed       action="$DEBOUNCE autofocus 200 $HOME/.config/yabai/autofocus.sh"
yabai -m signal --add event=application_terminated action="$DEBOUNCE autofocus 250 $HOME/.config/yabai/autofocus.sh"
```

The `system_woke`/`display_*` signals keep `$SYNC_BORDERS || true` unchanged
(rare events, no burst). The `space_changed`/`display_changed` auto-focus
signals stay unchanged (out of scope).

- [x] **Step 5: Verify scripts** — `bash -n debounce.sh autofocus.sh yabairc` (yabairc is sh: `sh -n yabairc`); `shellcheck darwin/home/config/yabai/debounce.sh darwin/home/config/yabai/autofocus.sh` clean (or documented waivers). Mark both scripts executable AND record the bit for git (`core.fileMode=false` in nix-config — gotcha #27): `chmod +x … && git update-index --chmod=+x darwin/home/config/yabai/debounce.sh darwin/home/config/yabai/autofocus.sh`; confirm `git ls-files -s` shows `100755`.

- [x] **Step 6: Functional smoke test of the debouncer** (safe, no yabai):

```bash
d="${TMPDIR:-/tmp}/yabai-debounce-test"; rm -rf "$d"; mkdir -p "$d"
for i in 1 2 3 4 5; do TMPDIR="$d" bash darwin/home/config/yabai/debounce.sh t 150 sh -c "echo run >> $d/out"; done
sleep 0.5; [ "$(wc -l < "$d/out")" -eq 1 ] && echo DEBOUNCE-OK
```

Expected: `DEBOUNCE-OK`.

- [x] **Step 7: Commit** (include the gotchas edit here if Task 10 found the skill file resolves into nix-config):

```bash
git add darwin/home/config/yabai/
git commit -m "perf(yabai): ⚡️ debounce sketchybar/border/auto-focus signal fan-out"
```

---

### Task 12: Independent review, integrate, deploy, verify, archive

- [x] **Step 1: Independent code review** — run the reviewing-code skill over the full appfocus branch diff (`git diff main...change/window-model`) against the spec. Address findings; commit fixes.
- [ ] **Step 2: Final green** — `make all && make test` ×3 in the worktree, plus a manual daemon smoke: stop the LaunchAgent (`launchctl bootout gui/$(id -u)/local.appfocus`), run `APPFOCUS_LOG=debug .build/appfocusd` briefly, exercise `appfocus jump …`/`next`, confirm `model` lines + zero per-command queries in the debug log, restart the LaunchAgent.
- [ ] **Step 3: Integrate appfocus** — `git wt-finish window-model` (publishes to origin/main, removes worktree). Note: the archive convention check — if `_changes/_archive/` exists on main, move the change folder there in a follow-up commit per repo convention.
- [ ] **Step 4: Overlay bump** — in the nix-config worktree from Task 11: update `overlays/appfocus.nix` rev to the new appfocus main SHA and the SRI hash via `nix-prefetch-url --unpack` (exact commands in the developing-appfocus skill). Also check `rg -n "poll_interval_ms" darwin/` — if the managed config.json pins 1000, change it to 2000 (or drop the field so the new default applies).
- [ ] **Step 5: Integrate nix-config** — `git wt-finish yabai-signal-debounce`, then `just switch` from the primary checkout (builds the new appfocus via crabbox). The yabairc/sketchybar files are out-of-store symlinks: live once primary syncs.
- [ ] **Step 6: Live verification** — `yabai --restart-service` (re-registers debounced signals; warn: brief tiling interruption), then `yabai -m signal --list | jq -r '.[].action' | grep -c debounce` > 0; `launchctl print gui/$(id -u)/local.appfocus` shows the new daemon; `appfocus status` sane; rapid-switch burst feels snappy; `tail -f ~/Library/Logs/appfocus/appfocusd.err.log` clean.
- [ ] **Step 7: Fitness baseline** — record the deploy timestamp; WATCHDOG fires/day comparison runs over the following days (baseline: 16 on 2026-08-14).
- [ ] **Step 8: Reconcile spec with as-built, archive the change folder per repo convention, run closing-loops.**

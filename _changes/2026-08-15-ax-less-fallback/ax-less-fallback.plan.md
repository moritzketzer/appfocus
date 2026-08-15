# AX-less Fallback Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a running app's only windows lack yabai AX references (ChatGPT Chromium lazy-AX state), jump switches to the window's Space and natively activates the app instead of uselessly reopening.

**Architecture:** One new predicate on `WindowInfo`, one new `AppLauncher` method (`open -a` activation), one new branch in `handleNoWindows` fed by the confirm query's unfiltered dump. Hot path untouched.

**Tech Stack:** Swift via Makefile, Swift Testing. `make test` runs everything.

**Worktree:** `.worktrees/ax-less-fallback`, branch `change/ax-less-fallback`.

---

### Task 1: Fallback behavior (TDD)

**Files:** Modify `Tests/Unit/ActivationLogicTests.swift`, `Tests/Unit/Mocks.swift`, `Sources/Daemon/Types.swift`, `Sources/Daemon/AppLauncher.swift`, `Sources/Daemon/ActivationLogic.swift`.

- [ ] **Step 1: Failing tests.** `win()` helper gains `role: String = "AXWindow"` and `ax: Bool = true` parameters (forwarded to `role`/`hasAXReference`). Mock launcher gains `activatedApps`. New tests:

```swift
    // MARK: - AX-less window fallback (ChatGPT Chromium lazy-AX state)

    @Test func jumpFallsBackToNativeActivationForAXlessWindows() {
        let h = Harness()
        h.processChecker.runningApps = ["ChatGPT"]
        h.backend.windows = [win(40, app: "ChatGPT", space: 4,
                                 subrole: "", role: "", ax: false)]
        // model not synced — confirm branch runs and sees the AX-less window

        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(h.backend.focusCalls == ["space:4"])
        #expect(h.launcher.activatedApps == ["ChatGPT"])
        #expect(h.launcher.reopenedApps.isEmpty)
        #expect(h.backend.focusedWindowIds.isEmpty)
        #expect(h.store.stateIfCached(for: "ChatGPT")?.lastFocusedId == nil)
        #expect(h.logic.isIdleForTesting)
    }

    @Test func stickyOverlayOnlyStillReopens() {
        let h = Harness()
        h.processChecker.runningApps = ["ChatGPT"]
        h.backend.windows = [win(41, app: "ChatGPT", subrole: "AXDialog",
                                 sticky: true, floating: true)]

        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(h.launcher.activatedApps.isEmpty)
        #expect(h.launcher.reopenedApps.count == 1)
    }
```

Mock addition (inside `MockAppLauncher`):

```swift
    var activatedApps: [String] = []

    func activate(appName: String, completion: @escaping () -> Void) {
        activatedApps.append(appName)
        completion()
    }
```

- [ ] **Step 2: Run, verify compile failure** (`activate` missing, `win` params missing).

- [ ] **Step 3: Implement.**

`Types.swift`, after `isStandardWindow`:

```swift
    /// A window that would be a standard jump target except yabai holds no
    /// AX reference for it. ChatGPT's Chromium build materializes its main
    /// window in the AX tree only while frontmost, so yabai can miss the
    /// reference entirely (empty role/subrole, unmanageable, unfocusable via
    /// yabai). Such a window can't be focused directly, but its Space is
    /// known and native activation reaches it.
    var isAXlessCandidate: Bool {
        !hasAXReference
            && role != "AXHelpTag"
            && !isSticky
            && subrole != "AXDialog"
            && subrole != "AXSystemDialog"
    }
```

`AppLauncher.swift`: add `func activate(appName: String, completion: @escaping () -> Void)` to the protocol; `DefaultAppLauncher` implements via the same `open -a` runner as `launch` (distinct log lines `Activated \(appName)` / `open -a \(appName) activate failed`), calling `completion()` regardless of exit status (activation is best-effort).

`ActivationLogic.swift` — `confirmNoWindows` computes candidates from the fresh dump and passes them:

```swift
            if windows.isEmpty {
                let axless = all.filter {
                    self.config.resolveAlias($0.appName) == appName
                        && !$0.isMinimized && $0.isAXlessCandidate
                }
                self.handleNoWindows(appName: appName, focused: focused,
                                     axlessCandidates: axless,
                                     token: token, done: done)
            } else {
```

`handleNoWindows` gains `axlessCandidates: [WindowInfo]` and branches before reopen:

```swift
        if isRunning {
            if let target = axlessCandidates.first {
                Log.error("jump: \(appName) has \(axlessCandidates.count) window(s) without AX reference — native fallback to space \(target.space); tiling needs a warm yabai restart (see gotchas)")
                backend.focusSpace(index: target.space) { [self] _ in
                    guard self.isActive(token) else { done(); return }
                    launcher.activate(appName: appName) { done() }
                }
                return
            }
            // ...existing reopen path unchanged
```

(`Log.error` so the line is visible without APPFOCUS_LOG=debug.) `main.swift` needs no change (launcher already wired). The launch path (`jumpNotRunningLaunchesApp`) ignores candidates.

- [ ] **Step 4: `make test` green ×2.**
- [ ] **Step 5: Commit** `feat: ✨ native-activation fallback for AX-less windows (ChatGPT lazy-AX)`.

### Task 2: Docs

- [ ] CLAUDE.md ActivationLogic bullets gain: `- **AX-less fallback**: a running app whose only windows lack yabai AX references (ChatGPT lazy-AX state) gets focusSpace + native activation instead of a useless reopen`. Commit `docs: 📝 …`.

### Task 3: Review, integrate, deploy

- [ ] Independent review of the branch diff (fresh subagent); fix/dispose findings; closure by same reviewer.
- [ ] Archive fold (completed+archived+`git mv` to `_changes/_archive/`), `git wt-finish ax-less-fallback`, ff primary.
- [ ] nix-config worktree: overlay bump to the new SHA + gotchas entry update ("future lever" → built, name the rev). wt-finish, ff primary, `just switch`.
- [ ] Live verify: daemon swapped, normal jump smoke; fallback path is unit-covered (broken state not reproducible on demand — will be observed via the new log line at next recurrence).

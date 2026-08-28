# Native-First App Activation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route cross-application jumps through AppKit bundle activation while preserving yabai-backed same-application window navigation.

**Architecture:** `ApplicationWorkspace` owns macOS application identity, activation, and activation notifications. `ActivationLogic` selects an application or window job before entering the pump; application jobs use `AppLauncher` and `OutcomeVerifier` without calling `WindowBackend`, while window jobs retain the current model, focus, watchdog, backoff, and retry behavior. Nix owns the 28 deployed bundle identifiers and checks every appfocus-backed Kanata binding for coverage.

**Tech Stack:** Swift 6, AppKit `NSWorkspace`, Swift Testing, Nix, jq, nix-darwin, Crabbox, launchd.

---

## Work Surfaces

- Appfocus worktree: `/Users/moritz/para/0-System/appfocus/.worktrees/native-app-activation`
- Appfocus branch: `change/native-app-activation`
- Nix-config worktree: `/Users/moritz/para/0-System/nix-config/.worktrees/appfocus-native-activation`
- Nix-config branch: `change/appfocus-native-activation`
- Appfocus specification: `_changes/2026-08-28-native-app-activation/native-app-activation.spec.md`
- Appfocus lifecycle: `_changes/2026-08-28-native-app-activation/change.yaml`

Keep both primary checkouts untouched until their corresponding worktree branch is published. The appfocus primary contains a foreign staged `flake.lock`; the nix-config primary contains foreign edits in two unrelated `_changes/*/change.yaml` files.

### Task 1: Add Application Identity and Bundle Configuration

**Files:**

- Create: `Sources/Daemon/ApplicationWorkspace.swift`
- Modify: `Sources/Daemon/Config.swift`
- Modify: `Tests/Unit/ConfigTests.swift`
- Modify: `Tests/Unit/Mocks.swift`

- [ ] **Step 1: Write failing config and workspace-mock tests.** Add `bundleIdentifiers` to the `testConfig` helper and add these tests:

```swift
@Test func bundleIdentifiersDefaultToEmpty() throws {
    let json = """
    {"backend":"yabai","yabai_path":"/usr/bin/yabai"}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppFocusConfig.self, from: json)
    #expect(config.bundleIdentifiers.isEmpty)
}

@Test func bundleIdentifierUsesCanonicalAliasTarget() {
    let config = testConfig(
        aliases: ["Word": "Microsoft Word"],
        bundles: ["Microsoft Word": "com.microsoft.Word"])
    #expect(config.bundleIdentifier(for: "Word") == "com.microsoft.Word")
    #expect(config.bundleIdentifier(for: "Microsoft Word") == "com.microsoft.Word")
}
```

Add a `MockApplicationWorkspace` with mutable `frontmostApplication`, bundle-to-URL lookup, opened URLs, pending open completions, and retained activation handlers:

```swift
final class MockApplicationWorkspace: ApplicationWorkspace, @unchecked Sendable {
    var frontmostApplication: ApplicationIdentity?
    var urls: [String: URL] = [:]
    var opened: [(URL, Bool)] = []
    var openResult: Result<ApplicationIdentity, Error> = .success(
        ApplicationIdentity(bundleIdentifier: "com.apple.Safari", localizedName: "Safari"))
    private var handlers: [(ApplicationIdentity) -> Void] = []

    func applicationURL(bundleIdentifier: String) -> URL? { urls[bundleIdentifier] }

    func openApplication(
        at url: URL,
        activates: Bool,
        completion: @escaping (Result<ApplicationIdentity, Error>) -> Void
    ) {
        opened.append((url, activates))
        completion(openResult)
    }

    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject {
        handlers.append(handler)
        return NSObject()
    }

    func emitActivation(_ identity: ApplicationIdentity) {
        frontmostApplication = identity
        handlers.forEach { $0(identity) }
    }
}
```

- [ ] **Step 2: Run the suite and verify RED.**

Run: `make clean && make test`

Expected: compilation fails because `ApplicationWorkspace`, `ApplicationIdentity`, `bundleIdentifiers`, and `bundleIdentifier(for:)` do not exist.

- [ ] **Step 3: Add the workspace boundary.** Implement these public shapes and the AppKit adapter:

```swift
struct ApplicationIdentity: Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
}

protocol ApplicationWorkspace {
    var frontmostApplication: ApplicationIdentity? { get }
    func applicationURL(bundleIdentifier: String) -> URL?
    func openApplication(
        at url: URL,
        activates: Bool,
        completion: @escaping (Result<ApplicationIdentity, Error>) -> Void
    )
    @discardableResult
    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject
}
```

`SystemApplicationWorkspace` wraps `NSWorkspace.shared`. It resolves URLs with `urlForApplication(withBundleIdentifier:)`, opens with `NSWorkspace.OpenConfiguration.activates`, converts `NSRunningApplication` into `ApplicationIdentity`, and returns a notification token whose `deinit` removes the `didActivateApplicationNotification` observer.

- [ ] **Step 4: Decode and resolve bundle identifiers.** Add the stored property, coding key, default, decoder fallback, and canonical lookup:

```swift
var bundleIdentifiers: [String: String]

case bundleIdentifiers = "bundle_identifiers"

func bundleIdentifier(for appName: String) -> String? {
    bundleIdentifiers[resolveAlias(appName)]
}
```

The decoder uses `decodeIfPresent([String: String].self, forKey: .bundleIdentifiers) ?? [:]`. Every explicit `AppFocusConfig(...)` initializer in tests receives `bundleIdentifiers: ...`.

- [ ] **Step 5: Run tests and verify GREEN.**

Run: `make clean && make test`

Expected: all suites pass, including both new config tests.

- [ ] **Step 6: Commit the boundary.**

```bash
git add Sources/Daemon/ApplicationWorkspace.swift Sources/Daemon/Config.swift Tests/Unit/ConfigTests.swift Tests/Unit/Mocks.swift
git commit -m "feat(appfocus): ✨ add native application identity"
```

### Task 2: Make Application Actions Result-Bearing

**Files:**

- Modify: `Sources/Daemon/AppLauncher.swift`
- Create: `Tests/Unit/AppLauncherTests.swift`
- Modify: `Tests/Unit/Mocks.swift`

- [ ] **Step 1: Write failing launcher tests.** Cover these three contracts with an injected command runner. Define the test recorder in `AppLauncherTests.swift`:

```swift
private struct CommandCall: Equatable {
    let executablePath: String
    let arguments: [String]

    init(_ executablePath: String, _ arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

private final class RecordingCommandRunner {
    var calls: [CommandCall] = []
    let result: Result<Int32, Error>

    init(exitStatus: Int32 = 0) {
        result = .success(exitStatus)
    }

    func run(
        executablePath: String,
        arguments: [String],
        completion: @escaping (Result<Int32, Error>) -> Void
    ) {
        calls.append(CommandCall(executablePath, arguments))
        completion(result)
    }
}
```

Then add the launcher cases:

```swift
@Test func configuredBundleUsesNativeActivation() {
    let workspace = MockApplicationWorkspace()
    let url = URL(fileURLWithPath: "/Applications/Passwords.app")
    workspace.urls["com.apple.Passwords"] = url
    workspace.openResult = .success(ApplicationIdentity(
        bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords"))
    let runner = RecordingCommandRunner()
    let launcher = DefaultAppLauncher(workspace: workspace, runCommand: runner.run)

    var result: ApplicationActionResult?
    launcher.activate(appName: "Passwords", bundleIdentifier: "com.apple.Passwords") {
        result = $0
    }

    #expect(workspace.opened.map(\.0) == [url])
    #expect(workspace.opened.map(\.1) == [true])
    #expect(runner.calls.isEmpty)
    #expect(result?.path == .nativeBundle)
    #expect(result?.success == true)
}

@Test func unknownConfiguredBundleFailsWithoutNameFallback() {
    let workspace = MockApplicationWorkspace()
    let runner = RecordingCommandRunner()
    let launcher = DefaultAppLauncher(workspace: workspace, runCommand: runner.run)

    var result: ApplicationActionResult?
    launcher.activate(appName: "Missing", bundleIdentifier: "invalid.bundle") {
        result = $0
    }

    #expect(result?.success == false)
    #expect(result?.path == .nativeBundle)
    #expect(runner.calls.isEmpty)
}

@Test func missingBundleUsesExplicitLegacyNamePath() {
    let workspace = MockApplicationWorkspace()
    let runner = RecordingCommandRunner(exitStatus: 0)
    let launcher = DefaultAppLauncher(workspace: workspace, runCommand: runner.run)

    var result: ApplicationActionResult?
    launcher.activate(appName: "Generic App", bundleIdentifier: nil) { result = $0 }

    #expect(runner.calls == [CommandCall("/usr/bin/open", ["-a", "Generic App"])])
    #expect(result?.path == .legacyName)
    #expect(result?.success == true)
}
```

Add one reopen test that expects `/usr/bin/osascript`, the selected script, `.reopen`, and `success == false` for a nonzero exit status.

- [ ] **Step 2: Run the suite and verify RED.**

Run: `make clean && make test`

Expected: compilation fails because `ApplicationActionResult`, `ApplicationActionPath`, the new `activate` signature, and command-runner injection do not exist.

- [ ] **Step 3: Replace the launcher protocol.** Use these result types and operations:

```swift
enum ApplicationActionPath: String, Equatable {
    case nativeBundle = "native-bundle"
    case legacyName = "legacy-name"
    case reopen
}

struct ApplicationActionResult: Equatable {
    let success: Bool
    let path: ApplicationActionPath
    let bundleIdentifier: String?
    let detail: String?
}

protocol AppLauncher {
    func activate(
        appName: String,
        bundleIdentifier: String?,
        completion: @escaping (ApplicationActionResult) -> Void
    )
    func reopen(
        appName: String,
        strategy: ReopenStrategy,
        completion: @escaping (ApplicationActionResult) -> Void
    )
}
```

Use this injectable runner signature:

```swift
typealias ApplicationCommandRunner = (
    _ executablePath: String,
    _ arguments: [String],
    _ completion: @escaping (Result<Int32, Error>) -> Void
) -> Void
```

For a nonempty bundle identifier, resolve the URL and call `workspace.openApplication(at:activates:true)`. A missing URL and an AppKit error return `.nativeBundle` failure with the bundle identifier in `detail`; neither path invokes `/usr/bin/open`. A nil bundle identifier invokes `/usr/bin/open -a <canonical-name>` and reports `.legacyName`. Reopen reports the actual `osascript` exit status as `.reopen`.

- [ ] **Step 4: Update `MockAppLauncher`.** Add an equatable `ApplicationActivationCall` struct with `appName` and `bundleIdentifier`, then record `[ApplicationActivationCall]` plus configurable `ApplicationActionResult` values for activation and reopen. Remove `launchedApps`, `activatedApps`, and `launchSuccess` after their callers migrate in later tasks; until then, keep compiler-compatible adapters only on the test branch and remove them before Task 6 commits.

- [ ] **Step 5: Run tests and verify GREEN.**

Run: `make clean && make test`

Expected: `AppLauncherTests` pass and no production code shells out by name for an explicit bundle identifier.

- [ ] **Step 6: Commit the launcher.**

```bash
git add Sources/Daemon/AppLauncher.swift Tests/Unit/AppLauncherTests.swift Tests/Unit/Mocks.swift
git commit -m "feat(appfocus): ✨ activate apps by bundle identifier"
```

### Task 3: Add Application Verification Without Yabai

**Files:**

- Modify: `Sources/Daemon/CommandTrace.swift`
- Modify: `Sources/Daemon/OutcomeVerifier.swift`
- Modify: `Tests/Unit/CommandTraceTests.swift`
- Modify: `Tests/Unit/OutcomeVerifierTests.swift`

- [ ] **Step 1: Write failing trace and verifier tests.** Add the explicit target kind and exercise both workspace evidence sources:

```swift
@Test func applicationTargetEncodesIdentity() {
    let trace = CommandTrace(command: "jump", app: "Passwords")
    trace.verificationTargetKind = .application
    trace.targetBundleIdentifier = "com.apple.Passwords"
    let obj = parse(trace.jsonLine())
    #expect(obj["target_kind"] as? String == "application")
    #expect(obj["target_bundle_id"] as? String == "com.apple.Passwords")
}

@Test func nativeApplicationVerificationNeverQueriesBackend() {
    let h = VerifierHarness()
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords")
    let trace = h.applicationTrace(app: "Passwords", bundle: "com.apple.Passwords")
    h.verifier.verify(trace)
    let records = h.waitForRecords(1)
    #expect(records.first?["outcome"] as? String == "ok-app")
    #expect(h.backend.queryAllWindowsCallCount == 0)
}

@Test func activationNotificationCanVerifyNativeApplication() {
    let h = VerifierHarness()
    let trace = h.applicationTrace(app: "Passwords", bundle: "com.apple.Passwords")
    h.verifier.verify(trace)
    h.workspace.emitActivation(ApplicationIdentity(
        bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords"))
    let records = h.waitForRecords(1)
    #expect(records.first?["outcome"] as? String == "ok-app")
    #expect(h.backend.queryAllWindowsCallCount == 0)
}
```

Add cases for wrong bundle (`wrong-window`), legacy localized-name success, pre-failed application trace, and application burst coalescing. Preserve every current window-verification test.

- [ ] **Step 2: Run tests and verify RED.**

Run: `make clean && make test`

Expected: compilation fails because application verification fields and workspace injection do not exist.

- [ ] **Step 3: Add the trace target.** Define and serialize:

```swift
enum VerificationTargetKind: String, Equatable {
    case window
    case application
}

var verificationTargetKind: VerificationTargetKind = .window
var targetBundleIdentifier: String?
```

`jsonLine` writes `target_kind` for every trace and `target_bundle_id` when present. Add a locked `verificationTarget` snapshot so `OutcomeVerifier` reads the kind, app, bundle identifier, and window identifier atomically.

- [ ] **Step 4: Split verifier execution by target kind.** Inject `ApplicationWorkspace` into `OutcomeVerifier` and retain its activation observer. Cache each observed identity with `DispatchTime.now()`. At `fire`, call `backend.queryAllWindows` only for `.window`. For `.application`, prefer `workspace.frontmostApplication`; use the cached notification only when its timestamp is at or after the trace's `actionedAt` (or `receivedAt` when no action time exists). This prevents a stale activation notification from verifying a later command. Classify without touching `backend` or `model`:

```swift
if let expectedBundle = target.bundleIdentifier {
    trace.outcome = actual.bundleIdentifier == expectedBundle ? "ok-app" : "wrong-window"
} else if let expectedName = target.app {
    trace.outcome = actual.localizedName.map(resolveAlias) == expectedName
        ? "ok-app" : "wrong-window"
}
```

Keep `wrong-window` for a mismatched frontmost application and append its bundle/name to `detail`. Preserve delayed coalescing, `commandStarted`, `unverified-burst`, window classification, and model refresh.

- [ ] **Step 5: Run tests and verify GREEN.**

Run: `make clean && make test`

Expected: all legacy window tests and the new application tests pass; every application test asserts `queryAllWindowsCallCount == 0`.

- [ ] **Step 6: Commit verification.**

```bash
git add Sources/Daemon/CommandTrace.swift Sources/Daemon/OutcomeVerifier.swift Tests/Unit/CommandTraceTests.swift Tests/Unit/OutcomeVerifierTests.swift
git commit -m "feat(appfocus): ✨ verify native app activation"
```

### Task 4: Route Cross-Application Jumps Before Window State

**Files:**

- Modify: `Sources/Daemon/ActivationLogic.swift`
- Modify: `Tests/Unit/ActivationLogicTests.swift`
- Modify: `Tests/Unit/Mocks.swift`

- [ ] **Step 1: Make the activation harness identity-aware.** Give `Harness` a `MockApplicationWorkspace`, a `bundles` argument, and a default frontmost Safari identity. Tests that exercise same-application window behavior set the workspace identity to that target. Tests that exercise cross-application behavior set it to `Other`.

- [ ] **Step 2: Write failing cross-application tests.** Add configured and compatibility cases:

```swift
@Test func passwordsCrossAppJumpUsesNativeActivationWithoutYabai() {
    let h = Harness(bundles: ["Passwords": "com.apple.Passwords"])
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
    h.launcher.activationResult = ApplicationActionResult(
        success: true, path: .nativeBundle,
        bundleIdentifier: "com.apple.Passwords", detail: nil)

    h.logic.jump(appName: "Passwords")
    h.settle()

    #expect(h.launcher.activationCalls.count == 1)
    #expect(h.launcher.activationCalls.first?.appName == "Passwords")
    #expect(h.launcher.activationCalls.first?.bundleIdentifier == "com.apple.Passwords")
    #expect(h.backend.queryAllWindowsCallCount == 0)
    #expect(h.backend.focusCalls.isEmpty)
    #expect(h.telemetry.verified.first?.verificationTargetKind == .application)
    #expect(h.telemetry.verified.first?.path == "native-bundle")
}

@Test func safariCrossAppJumpUsesNativeActivationWithoutModel() {
    let h = Harness(bundles: ["Safari": "com.apple.Safari"])
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.cmuxterm.app", localizedName: "cmux")
    h.logic.jump(appName: "Safari")
    h.settle()
    #expect(h.launcher.activationCalls.count == 1)
    #expect(h.backend.queryAllWindowsCallCount == 0)
    #expect(h.backend.focusCalls.isEmpty)
}

@Test func genericCrossAppJumpUsesLegacyNamePath() {
    let h = Harness()
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
    h.launcher.activationResult = ApplicationActionResult(
        success: true, path: .legacyName, bundleIdentifier: nil, detail: nil)
    h.logic.jump(appName: "Generic App")
    h.settle()
    #expect(h.telemetry.verified.first?.path == "legacy-name")
    #expect(h.backend.queryAllWindowsCallCount == 0)
}
```

Add a test proving `Word` resolves to `Microsoft Word` before bundle lookup. Add a failed-result test that records `failed` immediately and does not call the backend.

- [ ] **Step 3: Run tests and verify RED.**

Run: `make clean && make test`

Expected: cross-application tests fail because `jump` still reads `WindowModel` and uses window actions.

- [ ] **Step 4: Choose the domain at command entry.** Inject `ApplicationWorkspace` into `ActivationLogic`. At the start of `jump`, resolve the alias, read the configured bundle and frontmost identity once, then choose:

```swift
let targetIsFrontmost: Bool
if let bundleIdentifier {
    targetIsFrontmost = frontmost?.bundleIdentifier == bundleIdentifier
} else {
    targetIsFrontmost = frontmost?.localizedName.map(config.resolveAlias) == appName
}
```

When `targetIsFrontmost` is false, submit an application job. Set `verificationTargetKind = .application`, store `targetBundleIdentifier`, call `launcher.activate`, copy `result.path.rawValue`, set `decidedAt` and `actionedAt`, and mark a failed result immediately. Do not call `model`, `store`, `backend`, or reopen from this branch. When `targetIsFrontmost` is true, submit the current window job and keep `performJump` as the entry to window behavior.

- [ ] **Step 5: Run tests and verify GREEN.**

Run: `make clean && make test`

Expected: configured Passwords and Safari jumps call zero `WindowBackend` methods; same-app MRU and ring tests still pass after their workspace fixture reflects the target app.

- [ ] **Step 6: Commit routing.**

```bash
git add Sources/Daemon/ActivationLogic.swift Tests/Unit/ActivationLogicTests.swift Tests/Unit/Mocks.swift
git commit -m "feat(appfocus): ✨ route cross-app jumps natively"
```

### Task 5: Isolate Application and Window Pump Failures

**Files:**

- Modify: `Sources/Daemon/ActivationLogic.swift`
- Modify: `Tests/Unit/ActivationLogicTests.swift`

- [ ] **Step 1: Write failing domain-isolation tests.** Cover breaker bypass, breaker preservation, native timeout, cycle supersession, and same-target ordering:

```swift
@Test func nativeJumpBypassesAndPreservesWindowBreaker() {
    let h = Harness(bundles: [
        "Safari": "com.apple.Safari",
        "Passwords": "com.apple.Passwords",
    ])
    h.logic.hungBackoff = 3600
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
    h.backend.windows = [win(1, app: "Safari")]
    h.backend.focusedWin = win(1, app: "Safari")
    h.sync()
    h.backend.focusWindowCompletesImmediately = false

    h.logic.jump(appName: "Safari")
    h.settle(ms: 50_000)
    h.logic.fireWatchdogNowForTesting()

    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.cmuxterm.app", localizedName: "cmux")
    h.logic.jump(appName: "Passwords")
    h.settle()
    #expect(h.launcher.activationCalls.last?.appName == "Passwords")

    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
    h.logic.jump(appName: "Safari")
    h.settle()
    #expect(h.telemetry.all.contains { $0.outcome == "dropped-backoff" })
}

@Test func nativeTimeoutDoesNotArmWindowBackoffOrRetry() {
    let h = Harness(bundles: ["Passwords": "com.apple.Passwords"])
    h.logic.applicationDeadline = 0.01
    h.launcher.activationCompletesImmediately = false
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
    h.logic.jump(appName: "Passwords")
    h.settle(ms: 200_000)
    #expect(h.telemetry.all.contains { $0.outcome == "native-timeout" })
    #expect(h.logic.isIdleForTesting)
    #expect(h.backend.focusedWindowIds.isEmpty)
}
```

Add a hanging cycle followed by a native app jump; assert the cycle is `superseded` and the app job runs immediately. Add two queued native jumps to the same target while the workspace still reports the prior frontmost app; assert both launcher completions are consumed in application order. Then emit the target as frontmost, issue a third jump, and assert it enters the window path. Add different native targets and assert last-write-wins supersession.

- [ ] **Step 2: Run tests and verify RED.**

Run: `make clean && make test`

Expected: breaker bypass, app deadline, and cycle supersession tests fail under the single-domain pump.

- [ ] **Step 3: Add pump domains.** Define:

```swift
private enum JobDomain {
    case application
    case window
}

private struct PumpJob {
    let domain: JobDomain
    let app: String?
    let trace: CommandTrace
    let run: (_ token: UInt64, _ done: @escaping () -> Void) -> Void
}

var applicationDeadline: TimeInterval = 3.0
```

Track `runningDomain`. Apply `hungUntil`, queue cap, `inFlightTarget`, retry arming, and `watchdogFire` only to window jobs. An application job supersedes every running window job, including a cycle with `app == nil`. Different application targets supersede; repeated identical targets queue.

- [ ] **Step 4: Give application jobs an independent deadline.** `runJob` installs one call-once completion gate shared by the normal callback and its domain timer. Window expiry calls the current watchdog. Application expiry fences late callbacks, records `native-timeout`, advances the pump, preserves `hungUntil`, and leaves `pendingRetry` empty. `finish(token:domain:)` clears `hungUntil` only for `.window`.

- [ ] **Step 5: Run tests and verify GREEN.**

Run: `make clean && make test`

Expected: all domain-isolation tests pass; existing window watchdog, backoff, cap, one-shot retry, and random-sequence tests remain green.

- [ ] **Step 6: Commit pump isolation.**

```bash
git add Sources/Daemon/ActivationLogic.swift Tests/Unit/ActivationLogicTests.swift
git commit -m "fix(appfocus): 🐛 isolate native activation failures"
```

### Task 6: Remove Process Scanning and Post-Launch Window Polling

**Files:**

- Modify: `Sources/Daemon/ActivationLogic.swift`
- Delete: `Sources/Daemon/ProcessChecker.swift`
- Modify: `Sources/Daemon/main.swift`
- Modify: `Tests/Unit/ActivationLogicTests.swift`
- Modify: `Tests/Unit/Mocks.swift`

- [ ] **Step 1: Rewrite the slow-path tests before production code.** Replace process-state launch tests with frontmost empty-model behavior:

```swift
@Test func axlessFrontmostAppUsesNativeActivationWithoutSpaceFocusOrPolling() {
    let h = Harness(bundles: ["ChatGPT": "com.openai.codex"])
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.openai.codex", localizedName: "ChatGPT")
    h.backend.windows = [win(40, app: "ChatGPT", space: 4,
                             subrole: "", role: "", ax: false)]

    h.logic.jump(appName: "ChatGPT")
    h.settle()

    #expect(h.backend.queryAllWindowsCallCount == 1)
    #expect(h.backend.focusCalls.isEmpty)
    #expect(h.launcher.activationCalls.count == 1)
    #expect(h.launcher.activationCalls.first?.appName == "ChatGPT")
    #expect(h.launcher.activationCalls.first?.bundleIdentifier == "com.openai.codex")
    #expect(h.telemetry.verified.first?.verificationTargetKind == .application)
    #expect(h.telemetry.verified.first?.path == "native-axless")
}

@Test func frontmostWindowlessAppReopensWithoutPolling() {
    let h = Harness(strategies: ["Safari": .makeDocument],
                    bundles: ["Safari": "com.apple.Safari"])
    h.workspace.frontmostApplication = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
    h.backend.windows = []
    h.logic.jump(appName: "Safari")
    h.settle()
    #expect(h.backend.queryAllWindowsCallCount == 1)
    #expect(h.launcher.reopenedApps.first?.1 == .makeDocument)
    #expect(h.telemetry.verified.first?.verificationTargetKind == .application)
    #expect(h.telemetry.verified.first?.path == "reopen")
}
```

Keep the failed-confirm test and assert it performs no activation or reopen. Keep sticky-overlay tests and assert they reopen without `focusSpace`. Delete the former `launchedWindowAcrossSpacesFocusesSpaceBeforeWindow`, `jumpNotRunningLaunchesApp`, and process-checker branch tests because cross-app activation now owns cold starts.

- [ ] **Step 2: Run tests and verify RED.**

Run: `make clean && make test`

Expected: AX-less test observes `focusSpace`, and reopen tests still enter the 15 by 200 ms poll.

- [ ] **Step 3: Simplify the confirmed-empty branch.** Remove `ProcessChecker` from `ActivationLogic`. After the fresh confirm:

```swift
if !axlessCandidates.isEmpty {
    trace.path = "native-axless"
    launcher.activate(
        appName: appName,
        bundleIdentifier: config.bundleIdentifier(for: appName),
        completion: completeApplicationAction
    )
} else {
    trace.path = "reopen"
    launcher.reopen(
        appName: appName,
        strategy: config.reopenStrategy(for: appName),
        completion: completeApplicationAction
    )
}
```

Before either action, change the trace verification target to `.application` and set `targetBundleIdentifier` from config. Both callbacks set `actionedAt`, propagate failure detail, and call `done` immediately. Delete `windowPollMaxAttempts`, `windowPollInterval`, and `pollForWindow`. The confirm-query failure remains a failed immediate result and performs no reopen.

- [ ] **Step 4: Remove the obsolete process boundary.** Delete `Sources/Daemon/ProcessChecker.swift`, remove `MockProcessChecker`, and wire one shared `SystemApplicationWorkspace` into `DefaultAppLauncher`, `OutcomeVerifier`, and `ActivationLogic` in `main.swift`.

- [ ] **Step 5: Run tests and verify GREEN.**

Run: `make clean && make all && make test`

Expected: the daemon and CLI build, all tests pass, `rg -n 'ProcessChecker|pollForWindow|windowPollMaxAttempts' Sources Tests` returns no matches, and AX-less/reopen tests perform exactly one confirm query with no Space focus or post-action polling.

- [ ] **Step 6: Commit slow-path removal.**

```bash
git add Sources/Daemon/ActivationLogic.swift Sources/Daemon/main.swift Tests/Unit/ActivationLogicTests.swift Tests/Unit/Mocks.swift
git add -u Sources/Daemon/ProcessChecker.swift
git commit -m "refactor(appfocus): ♻️ remove launch window polling"
```

### Task 7: Update Telemetry and Appfocus Documentation

**Files:**

- Modify: `Tests/Unit/TelemetryStatsTests.swift`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `_changes/2026-08-28-native-app-activation/native-app-activation.spec.md`

- [ ] **Step 1: Add a telemetry accounting regression.** Feed `native-bundle`, `legacy-name`, and `native-axless` records into `TelemetryStats.aggregate`; assert three decided successes and the `other paths` count. No production aggregator change is required unless this test exposes a mismatch.

```swift
@Test func nativePathsRemainDecidedSuccesses() {
    let out = TelemetryStats.aggregate(lines: [
        line(outcome: "ok-app", path: "native-bundle", total: 80),
        line(outcome: "ok-app", path: "legacy-name", total: 90),
        line(outcome: "ok-app", path: "native-axless", total: 100),
    ])
    #expect(out.contains("100.0% (3/3 decided)"))
    #expect(out.contains("other paths   : n=3"))
}
```

- [ ] **Step 2: Run the suite.**

Run: `make clean && make test`

Expected: all tests pass. If RED exposes accounting drift, change only `Sources/Common/TelemetryStats.swift` enough to count the three paths as decided successes, then rerun the same test.

- [ ] **Step 3: Update README architecture and configuration.** Document `bundle_identifiers`, native cross-app activation, yabai same-app navigation, compatibility activation by name, and AppKit application verification. Remove claims that all jumps launch with `open -a`, that `NSWorkspace` only detects processes, and that every verification queries yabai.

- [ ] **Step 4: Update `CLAUDE.md`.** Replace `ProcessChecker`, launch polling, Space-first AX-less fallback, and the single-path watchdog description with the implemented application/window split and the exact telemetry paths.

- [ ] **Step 5: Add an as-built section to the spec.** Record the final Swift type and method names, any test fixture changes, and the test count. Do not change the authorized behavior or acceptance thresholds.

- [ ] **Step 6: Commit documentation and telemetry coverage.**

```bash
git add Tests/Unit/TelemetryStatsTests.swift README.md CLAUDE.md _changes/2026-08-28-native-app-activation/native-app-activation.spec.md Sources/Common/TelemetryStats.swift
git commit -m "docs(appfocus): 📝 describe native-first activation"
```

If `Sources/Common/TelemetryStats.swift` remains unchanged, omit it from `git add`.

### Task 8: Enforce Bundle Coverage in Nix

**Files:**

- Modify: `/Users/moritz/para/0-System/nix-config/.worktrees/appfocus-native-activation/shared/keybindings/providers/kanata-apps.nix`
- Modify: `/Users/moritz/para/0-System/nix-config/.worktrees/appfocus-native-activation/nix/checks.nix`
- Modify: `/Users/moritz/para/0-System/nix-config/.worktrees/appfocus-native-activation/darwin/home/config/appfocus/config.json`

- [ ] **Step 1: Add appfocus target metadata.** Extend `binding` with `appfocusTarget ? null` and merge it into `action` only when non-null. Add an `appfocusApp` wrapper that defaults its target to `args.label`. Convert the 28 aliases that invoke `(t! open ...)` to `appfocusApp`. Keep `vscode-workspace`, `projects`, and `kitty-project` on `app` with no target. Override `kitty` to `"kitty"` and Zoom to `"zoom.us"`.

```nix
action = {
  id = "${layer}.${id}";
  inherit label kind;
}
// (if appfocusTarget == null then { } else { inherit appfocusTarget; });

appfocusApp =
  args:
  app (
    args
    // {
      appfocusTarget = args.appfocusTarget or args.label;
    }
  );
```

- [ ] **Step 2: Add the existing-check assertion.** Extend `keybinding-registry` so jq loads the appfocus config, resolves aliases, requires exactly 28 unique appfocus targets, and requires a nonempty bundle identifier for each:

```nix
jq -e --slurpfile appfocusConfig ${../darwin/home/config/appfocus/config.json} '
  ($appfocusConfig[0].aliases // {}) as $aliases
  | ($appfocusConfig[0].bundle_identifiers // {}) as $bundles
  | ([
      .bindings[]
      | select(.action.appfocusTarget? != null)
      | .action.appfocusTarget
      | ($aliases[.] // .)
    ] | unique) as $targets
  | ($targets | length) == 28
    and ($targets | all(
      . as $target
      | (($bundles[$target] // "") | type == "string" and length > 0)
    ))
' "$out/registry.json" >/dev/null || {
  echo "FAIL: every appfocus-backed Kanata app requires a bundle identifier" >&2
  exit 1
}
```

- [ ] **Step 3: Run the focused check and verify RED before adding the map.**

Run from the nix-config worktree:

```bash
nix-config-crabbox --reason implementation build darwin \
  .#checks.aarch64-darwin.keybinding-registry
```

Expected: FAIL with `every appfocus-backed Kanata app requires a bundle identifier` because `bundle_identifiers` is absent. Local `pytest` is unavailable and must not be installed ad hoc.

- [ ] **Step 4: Add the 28 checked identifiers.** Insert this object in `config.json` after `aliases`:

```json
"bundle_identifiers": {
  "Signal": "org.whispersystems.signal-desktop",
  "WhatsApp": "net.whatsapp.WhatsApp",
  "Messages": "com.apple.MobileSMS",
  "Obsidian": "md.obsidian",
  "Zotero": "org.zotero.zotero",
  "Mail": "com.apple.mail",
  "BusyCal": "com.busymac.busycal3",
  "Books": "com.apple.iBooksX",
  "Todoist": "com.todoist.mac.Todoist",
  "MarkText+": "com.electron.app",
  "Notes": "com.apple.Notes",
  "Adobe Acrobat": "com.adobe.Acrobat.Pro",
  "Reminders": "com.apple.reminders",
  "Dictionary": "com.apple.Dictionary",
  "ChatGPT": "com.openai.codex",
  "sioyek": "info.sioyek.sioyek",
  "Safari": "com.apple.Safari",
  "Google Chrome": "com.google.Chrome",
  "Finder": "com.apple.finder",
  "Spotify": "com.spotify.client",
  "zoom.us": "us.zoom.xos",
  "Photos": "com.apple.Photos",
  "kitty": "net.kovidgoyal.kitty",
  "Visual Studio Code": "com.microsoft.VSCode",
  "Passwords": "com.apple.Passwords",
  "cmux": "com.cmuxterm.app",
  "Microsoft Word": "com.microsoft.Word",
  "System Settings": "com.apple.systempreferences"
}
```

- [ ] **Step 5: Rerun the focused check and verify GREEN.**

Run the same Crabbox command.

Expected: the `keybinding-registry` derivation builds successfully. Inspect the generated registry and verify the three direct actions lack `appfocusTarget`.

- [ ] **Step 6: Commit the Nix contract.**

```bash
git add shared/keybindings/providers/kanata-apps.nix nix/checks.nix darwin/home/config/appfocus/config.json
git commit -m "feat(appfocus): ✨ declare native bundle identities"
```

### Task 9: Replace the Obsolete Appfocus Reference

**Files:**

- Modify: `/Users/moritz/para/0-System/nix-config/.worktrees/appfocus-native-activation/shared/agent/skills/_shelf/developing-appfocus/references/gotchas.md`

- [ ] **Step 1: Capture the reference RED.** Extract the `ChatGPT/Codex main window invisible to yabai` entry and prove it still prescribes `focusSpace(candidate.space)` plus `open -a` under `workspaces-auto-swoosh = false`:

```bash
python3 - <<'PY'
from pathlib import Path
p = Path("shared/agent/skills/_shelf/developing-appfocus/references/gotchas.md")
text = p.read_text()
section = text.split("### ChatGPT/Codex main window invisible to yabai", 1)[1]
section = section.split("\n## ", 1)[0]
assert "workspaces-auto-swoosh = false" in section
assert "focusSpace(candidate.space)" in section
assert "open -a" in section
print("RED: obsolete Space-first AX-less guidance retrieved")
PY
```

Expected: `RED: obsolete Space-first AX-less guidance retrieved`.

- [ ] **Step 2: Replace only the obsolete guidance.** Preserve the AX diagnosis and warm-yabai tiling recovery. Replace the runtime mitigation with the deployed native-first rule: cross-app bundle activation uses `NSWorkspace`, `workspaces-auto-swoosh = true` follows the application to its Space, application verification reads the workspace, and yabai remains responsible for same-app window focus. State that `native-axless` performs no explicit Space focus or post-activation poll.

- [ ] **Step 3: Replay the same retrieval as GREEN.**

```bash
python3 - <<'PY'
from pathlib import Path
p = Path("shared/agent/skills/_shelf/developing-appfocus/references/gotchas.md")
text = p.read_text()
section = text.split("### ChatGPT/Codex main window invisible to yabai", 1)[1]
section = section.split("\n## ", 1)[0]
assert "workspaces-auto-swoosh = true" in section
assert "NSWorkspace" in section
assert "bundle identifier" in section
assert "native-axless" in section
assert "focusSpace(candidate.space)" not in section
print("GREEN: native-first guidance retrieved and applicable")
PY
```

Expected: `GREEN: native-first guidance retrieved and applicable`.

- [ ] **Step 4: Run structural validation.**

```bash
python3 shared/agent/skills/writing-skills/scripts/validate_skill.py \
  shared/agent/skills/_shelf/developing-appfocus
```

Expected: no errors. Report warnings that name an actionable consequence; do not silently discard them.

- [ ] **Step 5: Commit the reference.**

```bash
git add shared/agent/skills/_shelf/developing-appfocus/references/gotchas.md
git commit -m "docs(appfocus): 📝 update native activation guidance"
```

### Task 10: Verify and Publish Appfocus Source

**Files:**

- Review: all appfocus branch changes
- Modify if required by review: only files already named by the specification

- [ ] **Step 1: Run the final source gate three consecutive times.**

```bash
for run in 1 2 3; do
  echo "appfocus verification run $run"
  make clean
  make all
  make test
done
```

Expected: three complete green runs with the same test count and no compiler warnings.

- [ ] **Step 2: Run focused invariant searches.**

```bash
! rg -n 'ProcessChecker|pollForWindow|windowPollMaxAttempts' Sources Tests
rg -n 'native-bundle|legacy-name|native-axless|native-timeout' Sources Tests README.md CLAUDE.md
rg -n 'focusSpace' Sources/Daemon/ActivationLogic.swift
```

Expected: removed process/poll symbols have no matches; every new path has production and test coverage; remaining `focusSpace` calls belong only to window focus.

- [ ] **Step 3: Review the full diff against the spec.** Use `reviewing-code` to test these distinct failure modes: an application path reaching `WindowBackend`, an app completion changing the yabai breaker, a late callback advancing the pump twice, an explicit invalid bundle falling back by name, and same-app MRU/cycle regressions. Record each finding as fixed, rejected with evidence, or absent.

- [ ] **Step 4: Apply and verify review fixes.** Add a failing regression test before each production fix. Rerun `make clean && make all && make test` after the final fix and commit each distinct correction.

- [ ] **Step 5: Publish the signed appfocus source while retaining the worktree.**

```bash
git status --short --branch
git log --show-signature -1 --format=fuller
git wt-publish native-app-activation
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

Expected: the branch tip and `origin/main` are identical signed commits. Record the exact SHA for the Nix pin. Keep the appfocus worktree until live acceptance and archive reconciliation finish.

### Task 11: Pin, Prewarm, Publish, and Deploy Nix-Config

**Files:**

- Modify: `/Users/moritz/para/0-System/nix-config/.worktrees/appfocus-native-activation/overlays/appfocus.nix`

- [ ] **Step 1: Compute the fixed-output hash for the published appfocus SHA.**

```bash
APPFOCUS_REV="$(git -C /Users/moritz/para/0-System/appfocus/.worktrees/native-app-activation rev-parse HEAD)"
nix-prefetch-url --unpack "https://github.com/moritzketzer/appfocus/archive/${APPFOCUS_REV}.tar.gz"
```

Expected: one base32 hash for the exact GitHub archive. Convert it with `nix hash convert --hash-algo sha256 --to sri <base32-hash>` and update `rev` plus `hash` in `overlays/appfocus.nix`.

- [ ] **Step 2: Commit the exact pin.**

```bash
git add overlays/appfocus.nix
git commit -m "build(appfocus): 📌 pin native activation"
```

- [ ] **Step 3: Rerun the focused Nix check.**

```bash
nix-config-crabbox --reason implementation build darwin \
  .#checks.aarch64-darwin.keybinding-registry
```

Expected: GREEN against the committed bundle map and provider metadata.

- [ ] **Step 4: Prewarm the exact MacBook system on Macserver.**

```bash
nix-config-crabbox --reason implementation prewarm darwin \
  .#darwinConfigurations.macbook.system
```

Expected: the MacBook system closure builds with the pinned appfocus revision and becomes available to the MacBook. Surface every warning with its consequence.

- [ ] **Step 5: Review the Nix diff.** Use `reviewing-code` to verify the 28-target count, alias resolution, the three direct-action exclusions, JSON validity, exact pin/hash, unchanged `workspaces-auto-swoosh = true` owner, and reference RED/GREEN evidence. Fix review findings test-first and rerun the affected check.

- [ ] **Step 6: Publish the signed nix-config branch while retaining its worktree.**

```bash
git status --short --branch
git log --show-signature -1 --format=fuller
git wt-publish appfocus-native-activation
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

Expected: signed `origin/main` equals the worktree tip.

- [ ] **Step 7: Recheck the primary before deployment.** The primary may fast-forward only when its unrelated working-tree changes remain intact. Do not stash, reset, clean, or overwrite those files. If the primary cannot reach the signed `origin/main` without touching them, stop at this deployment gate and report the exact conflicting paths.

- [ ] **Step 8: Deploy the signed exact main revision.** From the clean or safely fast-forwarded nix-config primary:

```bash
git rev-parse HEAD
git rev-parse origin/main
just switch
```

Expected: both SHAs match before `just switch`; deployment completes without a local appfocus build because the closure was prewarmed.

- [ ] **Step 9: Verify the deployed daemon and preference.**

```bash
launchctl print "gui/$(id -u)/local.appfocus"
readlink -f /etc/profiles/per-user/moritz/bin/appfocusd
defaults read com.apple.dock workspaces-auto-swoosh
appfocus status
```

Expected: LaunchAgent state is running; the executable resolves to a store path containing the new derivation; the preference is `1`; status returns valid JSON.

### Task 12: Run Controlled Foreground Acceptance

**Files:**

- Read: `~/.local/state/appfocus/telemetry.jsonl`
- Modify: `_changes/2026-08-28-native-app-activation/native-app-activation.spec.md`

- [ ] **Step 1: Capture the starting foreground state.** Record the frontmost bundle identifier and active yabai Space before any focus movement. Record the telemetry byte offset or timestamp that isolates acceptance records.

- [ ] **Step 2: Warn Moritz immediately before focus changes.** State that the next attended probe will switch applications and Spaces for approximately two minutes, and that the starting application and Space will be restored.

- [ ] **Step 3: Run one cold and nine warm Passwords jumps.** Terminate Passwords once for the cold case, send `appfocus jump Passwords`, then run nine warm jumps from a different frontmost application. After each command, poll `NSWorkspace.frontmostApplication.bundleIdentifier` and measure monotonic time to `com.apple.Passwords`.

Expected: 10 of 10 land on `com.apple.Passwords`; the isolated telemetry contains no `timeout` or `native-timeout` for Passwords.

- [ ] **Step 4: Run 30 same-Space and 30 cross-Space application jumps.** Use two configured applications whose existing windows establish the controlled same-Space and cross-Space cases. For each press, record target bundle, starting Space, ending Space, elapsed milliseconds, and frontmost bundle. Use condition polling rather than fixed sleeps.

Expected: 60 of 60 end on the requested bundle identifier; warm p95 is at most 300 ms for same-Space and at most 750 ms for cross-Space.

- [ ] **Step 5: Inspect native-path telemetry.** Filter records since the acceptance start for `native-bundle`, `legacy-name`, and `native-axless`.

Expected: no `timeout`, `native-timeout`, `dropped-backoff`, or `dropped-cap` outcomes on native paths. `ok-app` records account for every decided native press not superseded by the controlled sequence.

- [ ] **Step 6: Restore the starting application and Space.** Activate the recorded bundle and focus the recorded Space. Verify both values match the captured state before ending the attended probe.

- [ ] **Step 7: Record exact acceptance evidence in the as-built spec.** Add counts, p50/p95, failure counts, deployed appfocus SHA, deployed nix-config SHA, LaunchAgent store path, and `workspaces-auto-swoosh` value. Mark every number as checked from the acceptance run.

### Task 13: Reconcile, Archive, and Finish Both Worktrees

**Files:**

- Modify: `_changes/2026-08-28-native-app-activation/native-app-activation.spec.md`
- Modify: `_changes/2026-08-28-native-app-activation/change.yaml`
- Move: `_changes/2026-08-28-native-app-activation/` to `_changes/_archive/2026-08-28-native-app-activation/`

- [ ] **Step 1: Reconcile the spec with the deployed implementation.** Confirm every file and behavior claim against the final diffs, test output, signed SHAs, prewarm, deploy output, and acceptance evidence. Record deviations explicitly; no unresolved deviation may be hidden by archiving.

- [ ] **Step 2: Append lifecycle completion and archive events.** Use session `01a0476b-25ae-77a0-a053-104e6906eea1` and tool `codex`, set `status: archived`, append `completed`, then append `archived`.

- [ ] **Step 3: Move the change folder and commit the as-built archive.**

```bash
git mv _changes/2026-08-28-native-app-activation _changes/_archive/2026-08-28-native-app-activation
git add _changes/_archive/2026-08-28-native-app-activation
git commit -m "docs(appfocus): 📦 archive native activation change"
```

- [ ] **Step 4: Publish the archive commit and verify appfocus main.**

```bash
git wt-publish native-app-activation
git log --show-signature -1 --format=fuller
git ls-remote origin refs/heads/main
```

Expected: signed appfocus `origin/main` contains the archived as-built specification.

- [ ] **Step 5: Finish the appfocus worktree.** Run `git wt-finish native-app-activation`. The helper removes only the completed worktree and branch; the foreign staged `flake.lock` in the primary remains untouched.

- [ ] **Step 6: Finish the nix-config worktree.** After confirming the published nix-config commit is deployed, run `git wt-finish appfocus-native-activation`. Preserve the unrelated primary `_changes` edits.

- [ ] **Step 7: Run loop closure.** Use `closing-loops` to verify durable side effects: both signed main branches, MacBook deployment, running LaunchAgent, live preference, acceptance evidence, archived spec, and removed worktrees.

- [ ] **Step 8: Final report.** Link the archived as-built spec and report implemented behavior, changed files, test runs, independent review, signed SHAs, prewarm, deployment, live acceptance, archive, and loop-closure state. List only unresolved items that remain after the acceptance thresholds are evaluated.

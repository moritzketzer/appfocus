# Native-First App Activation

## Decision

`jump <App>` uses AppKit by bundle identifier whenever the target application
is not frontmost. Appfocus keeps yabai for same-application window selection,
MRU toggling, and `next` or `prev` cycling. This separates application
activation from window management without changing the Kanata command
protocol or adding a service.

The appfocus source repository owns the Swift behavior. The nix-config
repository owns the deployed bundle identifiers, Kanata coverage contract,
package pin, macOS Space preference, and the operator reference.

## Observed Problem

The current launcher runs `/usr/bin/open -a <name>`, then waits for yabai to
report a focusable window. That final condition is wrong for applications such
as Passwords whose yabai row lacks an Accessibility reference. Direct
`open -a Passwords` returned in 203 ms and made Passwords frontmost during the
first 200 ms observation. The corresponding appfocus command returned from the
CLI in 16 ms but recorded a timeout at its 3 s watchdog.

Telemetry from the preceding 24 hours contained 242 commands. Of 202 decided
commands, 146 succeeded (72.3%) and 52 timed out. Passwords had 15 records
since 2026-08-17: nine `timeout`, two `dropped-backoff`, two `dropped-cap`, and
two `superseded`, with no successful outcome. The hot-path p95 was 2549 ms and
the cross-Space p95 was 2487 ms.

The current AX-less fallback also depends on yabai: it focuses a Space before
calling `open -a`. That workaround matched the former
`workspaces-auto-swoosh = false` setting. Nix now declares the preference as
`true`, and `defaults read com.apple.dock workspaces-auto-swoosh` returned `1`
on 2026-08-28.

## Goals and Stopping Condition

This change optimizes three qualities:

- Correctness: every configured cross-application jump ends with the requested
  bundle identifier frontmost.
- Latency: application activation avoids the yabai window query and focus
  chain.
- Fault isolation: a yabai timeout or breaker cannot block native application
  activation.

The change stops when all configured Kanata app targets have bundle
identifiers, the test and deployment pipeline passes, and the live acceptance
run meets the thresholds in [Acceptance](#acceptance). No launcher UI, new
service, or additional application abstraction belongs in this change.

## Design Basis

The design uses the Architecture Tradeoff Analyzer from *Fundamentals of
Software Architecture*: application activation and window selection have
different failure modes, so they receive separate execution and verification
paths.

The reuse check covered macOS AppKit, `/usr/bin/open`, Raycast, and Alfred.
AppKit `NSWorkspace` already resolves and opens applications by bundle
identifier, activates running instances, exposes the frontmost application,
and publishes application-activation notifications. `/usr/bin/open -a` uses
LaunchServices but resolves by display name and does not fix the current yabai
success condition. Raycast and Alfred would add a second launcher
configuration while leaving appfocus's window MRU and ring behavior outside
their ownership. The implementation therefore uses AppKit directly and keeps
the existing name-based command only as an explicit compatibility path.

Primary API references:

- <https://developer.apple.com/documentation/appkit/nsworkspace>
- <https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/activates>
- <https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication>

## Application Identity

`AppFocusConfig` gains an optional `bundle_identifiers` object keyed by the
canonical application name after alias resolution:

```json
{
  "bundle_identifiers": {
    "Passwords": "com.apple.Passwords",
    "Safari": "com.apple.Safari",
    "Visual Studio Code": "com.microsoft.VSCode"
  }
}
```

The default remains an empty map so existing user configs decode unchanged.
The deployed config contains these locally checked identities:

| Canonical Name | Bundle Identifier |
|---|---|
| Signal | `org.whispersystems.signal-desktop` |
| WhatsApp | `net.whatsapp.WhatsApp` |
| Messages | `com.apple.MobileSMS` |
| Obsidian | `md.obsidian` |
| Zotero | `org.zotero.zotero` |
| Mail | `com.apple.mail` |
| BusyCal | `com.busymac.busycal3` |
| Books | `com.apple.iBooksX` |
| Todoist | `com.todoist.mac.Todoist` |
| MarkText+ | `com.electron.app` |
| Notes | `com.apple.Notes` |
| Adobe Acrobat | `com.adobe.Acrobat.Pro` |
| Reminders | `com.apple.reminders` |
| Dictionary | `com.apple.Dictionary` |
| ChatGPT | `com.openai.codex` |
| sioyek | `info.sioyek.sioyek` |
| Safari | `com.apple.Safari` |
| Google Chrome | `com.google.Chrome` |
| Finder | `com.apple.finder` |
| Spotify | `com.spotify.client` |
| zoom.us | `us.zoom.xos` |
| Photos | `com.apple.Photos` |
| kitty | `net.kovidgoyal.kitty` |
| Visual Studio Code | `com.microsoft.VSCode` |
| Passwords | `com.apple.Passwords` |
| cmux | `com.cmuxterm.app` |
| Microsoft Word | `com.microsoft.Word` |
| System Settings | `com.apple.systempreferences` |

`Word` continues to resolve to `Microsoft Word` before lookup. Other aliases
retain their current behavior.

## Native Workspace Boundary

A small `ApplicationWorkspace` protocol wraps the AppKit operations needed by
both activation and verification:

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
    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject
}
```

`SystemApplicationWorkspace` implements the protocol with
`NSWorkspace.shared`. The test suite uses a deterministic mock. This boundary
replaces `WorkspaceProcessChecker`; activation no longer needs a separate
running-process scan.

`AppLauncher` returns a result for every operation:

```swift
enum ApplicationActionPath: String {
    case nativeBundle = "native-bundle"
    case legacyName = "legacy-name"
    case reopen
}

struct ApplicationActionResult {
    let success: Bool
    let path: ApplicationActionPath
    let bundleIdentifier: String?
    let detail: String?
}
```

For a configured bundle identifier, the launcher resolves the application URL
and calls `NSWorkspace.openApplication` with activation enabled. A missing URL
or AppKit error returns failure. It never falls back to a display name for an
explicit configured identifier.

For an application absent from `bundle_identifiers`, the launcher preserves
`/usr/bin/open -a <canonical-name>`. This compatibility path returns
`legacy-name` in telemetry. Reopen strategies remain AppleScript-based and now
report their exit status instead of completing without a result.

## Jump Routing

`ActivationLogic.jump` resolves the alias and reads the current frontmost
application from `ApplicationWorkspace` before it enters a job domain.

1. If a configured bundle identifier differs from the frontmost bundle
   identifier, submit an application job and activate by bundle identifier.
2. If no bundle identifier is configured and the canonical target name differs
   from the frontmost localized name, submit an application job through
   `legacy-name`.
3. If the target application is already frontmost, submit a window job and
   keep the current WindowModel, MRU, and ring decisions.

The first two branches make zero `WindowBackend` calls. They do not query the
WindowModel, focus a Space, focus a window, poll for a window, or inspect the
running-process list.

The frontmost branch keeps the existing same-application behavior. Eligible
windows use the existing MRU or ring selection and the existing explicit
`focusSpace` followed by `focusWindow`. If the model is empty, the existing
fresh confirm query remains because it prevents duplicate Finder or Safari
windows after a stale model read.

After the confirm query:

- An AX-less candidate triggers native activation. Appfocus does not focus the
  candidate's Space and does not poll afterward.
- A truly windowless frontmost app runs its configured reopen strategy.
  Finder keeps `makeWindow`; Safari keeps `makeDocument`; other apps keep
  `reopen`. Appfocus does not poll afterward.
- A failed confirm query records failure and performs no reopen, as today.

## Separate Job Domains

`PumpJob` gains a domain: `application` or `window`.

Window jobs retain the current 3 s watchdog, one-second yabai backoff, queue
cap, and one-shot focus retry. A normal window-job completion clears the yabai
breaker.

Application jobs bypass the yabai breaker and never arm a window retry. A new
application job immediately supersedes any running window job, including a
cycle whose `runningApp` is nil. Application jobs use their own completion
deadline so an absent AppKit callback cannot wedge the pump. That deadline
records `native-timeout`, releases the job, and neither starts yabai backoff nor
clears an existing yabai backoff. A normal application completion also leaves
the yabai breaker unchanged.

Different application targets remain last-write-wins. Repeated commands for
the same target queue in order. Late callbacks retain the existing token fence
and cannot advance the pump twice.

The command keeps the domain chosen when it entered the pump. Any repeated
press that arrives before the target becomes frontmost remains an application
job. A press received after the target becomes frontmost enters the window
domain and keeps the existing MRU behavior.

## Outcome Verification and Telemetry

`CommandTrace` records an explicit verification target:

- `window`: existing target window identifier and optional canonical app.
- `application`: canonical app and expected bundle identifier. The legacy path
  may use the canonical localized name when no bundle identifier exists.

`OutcomeVerifier` retains its coalescing, supersession, and delayed attribution
rules. Window targets keep the current yabai snapshot classification and model
refresh. Application targets use activation notifications plus
`NSWorkspace.frontmostApplication`; they make zero `WindowBackend` calls.

Application verification records `ok-app` when the expected bundle identifier
is frontmost. The legacy path compares the canonical localized name after alias
resolution. An AppKit or name-launcher error records `failed` immediately.
Other frontmost applications retain the current `wrong-window` outcome so the
stats schema remains compatible.

The `path` field distinguishes `native-bundle`, `legacy-name`,
`native-axless`, `reopen`, `hot`, `confirm`, `retry`, and `noop`. Existing
latency fields remain unchanged.

## Nix and Keybinding Contract

The Kanata wire protocol stays `push-msg "jump <App>"`. The keybinding
registry provider marks each appfocus-backed application binding with its
canonical target. Direct actions such as `VS Code Workspace`, `Projects`, and
`Kitty Project` remain outside that set.

The existing `keybinding-registry` Nix check loads the generated registry and
`darwin/home/config/appfocus/config.json`. It resolves aliases and fails when
any appfocus target lacks a nonempty bundle identifier. The check prevents a
new Kanata app jump from silently entering the compatibility path.

`darwin/system/modules/system-settings/system-dock-and-spaces.nix` remains the
owner of `workspaces-auto-swoosh = true`. The change adds no second preference
owner. Deployment verification checks the live value remains `1`.

## Files and Responsibilities

### Appfocus Repository

- `Sources/Daemon/ApplicationWorkspace.swift`: AppKit identity, open, and
  activation-observation boundary.
- `Sources/Daemon/AppLauncher.swift`: result-bearing bundle activation,
  compatibility activation, and reopen execution.
- `Sources/Daemon/Config.swift`: bundle identifier decoding and lookup.
- `Sources/Daemon/ActivationLogic.swift`: frontmost routing, job domains, and
  removal of launch polling.
- `Sources/Daemon/OutcomeVerifier.swift`: native application verification.
- `Sources/Daemon/CommandTrace.swift`: application verification target and
  activation path telemetry.
- `Sources/Daemon/ProcessChecker.swift`: removed after all callers migrate to
  `ApplicationWorkspace`.
- `Sources/Daemon/main.swift`: construct and share the workspace adapter.
- `Tests/Unit/*`: mocks and focused behavior, config, verifier, launcher, pump,
  and telemetry tests.
- `README.md` and `CLAUDE.md`: current native-first architecture and config.
- `_changes/2026-08-28-native-app-activation/`: canonical spec, plan, lifecycle,
  and final as-built record.

### Nix-Config Repository

- `darwin/home/config/appfocus/config.json`: the 28 checked bundle identifiers.
- `shared/keybindings/providers/kanata-apps.nix`: appfocus target metadata for
  existing app actions only.
- `nix/checks.nix`: bundle-identifier coverage assertion in the existing
  registry check.
- `overlays/appfocus.nix`: source revision and fixed-output hash after the
  appfocus commit is published.
- `shared/agent/skills/_shelf/developing-appfocus/references/gotchas.md`: replace
  the obsolete AX-less Space-first guidance with the deployed native-first
  behavior and its diagnostics.

The architecture atlas needs no update. This change keeps the documented host,
service, trust, state, configuration, deployment, and recovery owners intact.

## As-Built Source State

The source implementation matches the native boundary in this specification.
`ApplicationWorkspace.swift` defines `ApplicationIdentity`,
`ApplicationWorkspace`, and `SystemApplicationWorkspace`. The system adapter
uses `NSWorkspace.urlForApplication(withBundleIdentifier:)`,
`openApplication(at:configuration:completionHandler:)`,
`frontmostApplication`, and `didActivateApplicationNotification`. The daemon
constructs one adapter and shares it with `DefaultAppLauncher`,
`OutcomeVerifier`, and `ActivationLogic`.

`AppLauncher.swift` defines `ApplicationActionPath`,
`ApplicationActionResult`, the `AppLauncher` protocol, and
`DefaultAppLauncher`. `activate(appName:bundleIdentifier:completion:)` uses
AppKit for configured bundle identifiers and `/usr/bin/open -a` only when the
identifier is absent. `reopen(appName:strategy:completion:)` reports the
`osascript` exit status. The former `ProcessChecker.swift` file and its protocol
adapters are absent.

`CommandTrace` exposes an atomic `VerificationTarget` snapshot containing the
target kind, canonical app, bundle identifier, window identifier, and action
timestamp. `OutcomeVerifier.classifyApplication` accepts fresh activation
notifications or the current frontmost application without calling
`WindowBackend`. It condition-polls AppKit every 50 ms for up to 10 seconds
because `NSWorkspace.openApplication` can complete before a cold application
becomes frontmost. `ActivationLogic` uses private `application` and `window`
job domains. Its `applicationDeadline` records `native-timeout`, while the
window domain retains the yabai watchdog, breaker, queue cap, and one-shot
retry.

The deterministic test fixtures are `MockApplicationWorkspace`,
`MockAppLauncher`, `MockWindowBackend`, and `MockOutcomeVerifier`.
`MockApplicationWorkspace` controls bundle URL resolution, open results,
frontmost identity, and activation notifications. `MockAppLauncher` controls
result-bearing activation and deferred callbacks for timeout, ordering, and
supersession tests. On 2026-08-28, `make test` passed 184 tests in 14 suites,
including a regression where Passwords becomes frontmost after the initial
verification delay.

## Failure Behavior

- Unknown configured bundle identifier: record `failed` with the bundle
  identifier and AppKit resolution error; do not try `open -a`.
- AppKit open error: record `failed`; leave yabai breaker and retry state
  unchanged.
- Missing bundle identifier: use the explicit `legacy-name` path and report it
  in telemetry.
- Native callback timeout: record `native-timeout`; release the application
  domain without yabai backoff or retry.
- Delayed foreground activation after a successful native callback: keep the
  application verification pending for up to 10 seconds, then record
  `wrong-window` only if AppKit still lacks matching activation evidence.
- Reopen command failure: record `failed` from the `osascript` exit status.
- Yabai hang during same-app navigation: retain the existing watchdog,
  backoff, queue cap, and one-shot focus retry.
- New command during pending verification: retain `unverified-burst` and
  supersession semantics.

The only ongoing maintenance cost is the bundle identifier map. The registry
coverage check makes that cost visible whenever a new Kanata app target is
added. MarkText+ currently exposes the generic identifier `com.electron.app`;
the check protects presence, while the live acceptance run protects correct
resolution on this machine.

## Verification

### Source Tests

The Swift suite must prove:

- Configured cross-application Passwords and Safari jumps make zero
  `WindowBackend` calls.
- A native jump runs while the yabai breaker is active and leaves that breaker
  active for later window jobs.
- An application timeout neither arms retry nor starts yabai backoff.
- AX-less frontmost applications use native activation without `focusSpace` or
  post-action polling.
- Native activation and reopen paths perform no 200 ms window polling.
- Same-application MRU, `next`, `prev`, explicit Space focus, supersession, and
  one-shot retry behavior remain unchanged.
- Invalid configured bundle identifiers fail without name fallback.
- Application verification uses the workspace adapter and never queries
  yabai.
- Application verification does not record `wrong-window` while a cold native
  activation is still within its bounded foreground wait.
- Burst coalescing and activation notifications produce deterministic
  `ok-app`, `wrong-window`, `failed`, `native-timeout`, and
  `unverified-burst` records.
- Telemetry aggregates `native-bundle`, `legacy-name`, and `native-axless`
  without changing decided-command accounting.

Run `make clean`, `make all`, and `make test` three consecutive times after the
final source diff. The baseline on 2026-08-28 passed 158 tests.

### Nix and Reference Checks

Run the focused `keybinding-registry` check on the Darwin Crabbox target. It
must fail before the bundle map is complete and pass afterward. Run the
developing-appfocus skill's structural and focused behavior validation after
the reference edit.

Prewarm the MacBook system from the Macserver:

```bash
nix-config-crabbox --reason implementation prewarm darwin \
  .#darwinConfigurations.macbook.system
```

The prewarm must build the exact pinned appfocus source and make the signed
closure available to the MacBook without a local build.

## Acceptance

After both repositories reach signed `main`, run `just switch` from the clean
nix-config primary checkout. Verify:

- the active LaunchAgent executable resolves to the store path built from the
  new appfocus revision;
- `launchctl print gui/$(id -u)/local.appfocus` reports a running daemon;
- `defaults read com.apple.dock workspaces-auto-swoosh` returns `1`;
- one cold and nine warm Passwords jumps end with `com.apple.Passwords`
  frontmost, with 10 of 10 successes and no timeout;
- 30 controlled same-Space and 30 controlled cross-Space application jumps
  land on the requested bundle identifier, with 100% correct outcomes;
- warm p95 is at most 300 ms on the same Space and at most 750 ms across
  Spaces;
- native paths record no `timeout`, `native-timeout`, `dropped-backoff`, or
  `dropped-cap` outcome.

The foreground acceptance run records the starting frontmost application and
Space, warns Moritz immediately before moving focus, and restores both after
the run.

## Rollout and Reversal

Publish the appfocus source first. The nix-config commit then pins that exact
revision and hash, runs the Darwin prewarm, reaches signed `main`, and deploys
with `just switch`. No state migration occurs; existing MRU and telemetry files
remain readable.

Rollback reverts the nix-config pin and config commit to appfocus revision
`b3b0ee66d8052fa34621f826b255f55671d1d401`, then runs `just switch`. The old
binary needs no migrated state because `bundle_identifiers` lives only in the
new config. It can decode the remaining fields unchanged.

## Non-Scope

- New Kanata bindings, command syntax, aliases, or layer behavior.
- A launcher UI, search index, fuzzy application matching, or Spotlight bridge.
- Removal of yabai, WindowModel, MRU state, ring cycling, focus retry, or the
  focus poller.
- Changes to the same-application `focusSpace` plus `focusWindow` sequence.
- Automatic yabai restart or retile after native activation.
- Fixes for the separate `workspace-profile.sh` jq warnings.
- A new architecture view or ADR.

## Authorized Pipeline

The exact standalone `ship` trigger authorizes this bounded full-lane change:
specification, plan, test-first implementation, independent review, commits,
publication of both repositories, Macserver prewarm, MacBook deployment, live
acceptance, as-built reconciliation, archive, and loop closure. Any discovered
change to a service, secret, schema, command protocol, keybinding behavior, or
architecture owner falls outside this specification and stops the run.

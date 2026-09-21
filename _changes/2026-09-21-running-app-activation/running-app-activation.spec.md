# Prefer the Running Application’s Bundle

## Decision

When a configured application is running, appfocus opens the bundle belonging
to that live process. It resolves an installed application by bundle identifier
only when no matching live process provides a bundle URL. This changes target
selection inside the existing AppKit integration and preserves its open and
reopen behavior.

The appfocus repository owns the implementation and tests. The nix-config
repository owns the package pin and MacBook deployment. Moritz reviews this
specification; the current Codex session owns implementation after approval.

## Evidence and Scope

On 2026-09-21, appfocus logged four failed Zotero activations between 12:29 and
13:06 Europe/Berlin. The errors named the Zotero 9.0.6 bundle under `/nix/store`
and `kLSNoExecutableErr`. The working process used
`/Applications/Nix Apps/Zotero.app`. Both bundles were registered and contained
byte-identical, executable main binaries. A later fresh AppKit query selected
the Applications copy; a subsequent daemon jump passed its `ok-app` check.

The historical cause of the transient LaunchServices state remains uncertain.
The checked defect is narrower: appfocus always resolves an installation,
even when a live process already identifies the intended bundle. This change
removes that unnecessary lookup for running applications. It does not promise
to eliminate every macOS launch or focus failure.

The baseline is appfocus `80679be`, containing implementation `0bcf23a`.
`make test` passed 186 tests in 14 suites on 2026-09-21.

## Upstream Comparison

AltTab stores `NSRunningApplication` and its bundle URL. Its windowless-app
branch opens that URL; its ordinary window branch uses process and window
identities with private WindowServer calls. The inspected source is
[Window.swift, revision 56891e0](https://github.com/lwouis/alt-tab-macos/blob/56891e08861e2d43fafb31d58a4c7fd9ba2289ec/src/switcher/state/Window.swift#L343-L423).
The local AltTab version is 11.6.0; the inspected upstream revision is not
claimed to be its exact build source.

Direct process activation through `NSRunningApplication.activate` would avoid
opening a bundle altogether, but it would also change windowless-app reopen
behavior. Copying AltTab’s window backend would add private API maintenance
and replace behavior already owned by yabai. Using the live bundle URL retains
the existing `NSWorkspace.openApplication` behavior with a smaller change.

## Required Behavior

`SystemApplicationWorkspace.applicationURL(bundleIdentifier:)` reads current
running applications on every request. It filters by exact bundle identifier,
ignores terminated applications, and prefers the matching frontmost process.
Otherwise it selects the first matching live process with a bundle URL in
AppKit’s returned order. This supplies a defined tie-break without a new
multi-instance selection feature.

A live bundle URL wins even when the installation resolver would return a
different, missing, or unlaunchable copy. The installation resolver must not
run on that path. When no live candidate supplies a URL, the existing
`urlForApplication(withBundleIdentifier:)` path remains responsible for cold
launches. A subsequent request sees newly launched or terminated processes;
appfocus stores no additional application-path cache.

`DefaultAppLauncher` continues to open the selected URL with activation enabled.
AppKit errors remain failures. Configured bundle identifiers never fall back
to display names. Existing application verification must still observe the
requested application becoming frontmost; an open callback alone is not
success.

Production changes belong in `Sources/Daemon/ApplicationWorkspace.swift`.
`Sources/Daemon/AppLauncher.swift` may change only if needed to expose the
selection boundary to its existing tests. Test changes belong in
`Tests/Unit/ApplicationWorkspaceTests.swift`, `AppLauncherTests.swift`, and
their shared `Mocks.swift`. Use the existing dependency-injection convention
with the smallest seam that exercises production selection logic.
Any disposable cold-launch fixture belongs under `Tests/Fixtures/` and builds
only into `.build/`; it is never installed as a workstation application.

## Regression and Live Acceptance

Write the regression before changing selection and demonstrate its failure
against the current implementation. The tests must cover:

- A running Zotero bundle in Applications while installation lookup points
  to the Store copy: select and open the running bundle without that lookup.
- A missing installation result while a matching process still supplies a
  bundle URL: activate through the live URL.
- Terminated and unrelated processes: ignore them; preserve cold lookup when
  no live matching bundle exists.
- A process restart at another bundle path: the next request uses the new
  live bundle, not the prior result.
- Multiple matching processes: apply the documented frontmost-first rule.
- Existing cold launch, explicit errors, name compatibility, and reopen
  behavior: keep their current test expectations.

Run `make all` and the complete `make test` suite. Existing rapid-command,
supersession, MRU, window-cycle, timeout, and outcome-verification regressions
must remain green. Tests must exercise the production selector, not reproduce
the desired selection solely inside a mock.

After deployment, run the existing foreground benchmark and a focused Zotero
check. Twenty alternating warm jumps must reach the intended app, preserve
Zotero’s PID, and produce no corrupt-app errors. Check same-Space and cross-Space
focus, with warm p95 at most 300 ms and 700 ms respectively, matching the
existing benchmark’s stricter limit. Verify a cold launch with a disposable
test application; do not quit Zotero or another working app to create that
condition. Warn before moving focus and restore the starting app and Space.

## Delivery, Maintenance, and Reversal

Approval starts planning, test-first implementation, independent review,
signed source publication, the corresponding nix-config pin update, MacBook
deployment, live acceptance, and archive. The pin update is limited to
`overlays/appfocus.nix`; record the discovered edge case in the existing
`developing-appfocus/references/gotchas.md` operator reference as part of the
same delivery. Preserve unrelated files and the dirty primary checkout.

The change adds no dependency, service, background polling, configuration
field, LaunchServices database mutation, retry controller, permission, secret,
or stored-state migration. Maintenance consists of this selection rule and its
regressions. The residual risks are macOS refusing an otherwise valid open,
a process exiting during activation, and invalid cold-launch registrations;
existing error reporting and outcome checks remain in force.

Rollback restores the previous appfocus pin, revision
`0bcf23a02090752bba53eff6e7678a3250cae8a3`, through the normal nix-config delivery
route and reactivates the MacBook. No user-data rollback is needed. Stop when
the regression, full suite, deployed identity, and live acceptance pass.

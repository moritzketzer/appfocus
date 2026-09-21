# Running Application Bundle Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate a running Zotero through its live bundle and retain cold launching.

**Architecture:** Keep selection in `SystemApplicationWorkspace`. Test the real selector and launcher through the existing injected `NSWorkspace`, substituting only AppKit process data and OS open calls.

**Tech Stack:** Swift, AppKit, Swift Testing, Nix.

## 1. Reproduce the Selection Defect

Files: create `Tests/Unit/ApplicationWorkspaceTests.swift`; existing callers are `Sources/Daemon/AppLauncher.swift` and `Sources/Daemon/main.swift`.

- [ ] Add test-only subclasses of `NSWorkspace` and `NSRunningApplication` that expose configured process lists, frontmost process, installed URL, and record open requests. Do not implement selection in the doubles.
- [ ] Exercise the production workspace with a live `/Applications/Nix Apps/Zotero.app` and installed `/nix/store/old-zotero/Applications/Zotero.app`:

```swift
let workspace = SystemApplicationWorkspace(workspace: system)
#expect(workspace.applicationURL(bundleIdentifier: "org.zotero.zotero") == liveURL)
#expect(system.resolvedIdentifiers.isEmpty)
```

- [ ] Run `make test > .build/regression-red.log 2>&1`; require assertion failures showing the Store URL selected and resolver invoked. Compile errors do not count as RED.
- [ ] Cover a nil installed result, terminated/unrelated/nil-URL processes, replacement process URL on the next request, and frontmost preference. Drive `DefaultAppLauncher` through this production workspace and assert that its open request has the live URL and activation enabled.

## 2. Select the Live Bundle

File: `Sources/Daemon/ApplicationWorkspace.swift`.

- [ ] Replace only `applicationURL(bundleIdentifier:)` with the live-first selection:

```swift
if let app = workspace.frontmostApplication,
   app.bundleIdentifier == bundleIdentifier, !app.isTerminated,
   let url = app.bundleURL {
    return url
}
for app in workspace.runningApplications
    where app.bundleIdentifier == bundleIdentifier && !app.isTerminated {
    if let url = app.bundleURL { return url }
}
return workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
```

- [ ] Run `make all > .build/build.log 2>&1` and `make test > .build/regression-green.log 2>&1`. Require all existing and added tests passing; inspect compiler warnings separately from intentional error-path test logs.
- [ ] Commit the production change and regressions with a signed commit after `git diff --check`.

## 3. Review and Deliver

Files: change history and evidence in this change directory; nix-config `overlays/appfocus.nix` and `shared/agent/skills/developing-appfocus/references/gotchas.md` in an isolated nix-config worktree.

- [ ] Obtain independent review against the approved spec; resolve concrete findings and repeat only affected checks.
- [ ] Publish appfocus through `git wt-finish running-app-activation`. Preserve the dirty primary checkout.
- [ ] Update the existing Nix source revision and fixed-output hash to the published implementation; add the observed duplicate-registration gotcha to its existing reference.
- [ ] Select the focused appfocus Darwin installable from the checked flake and run `nix-config-crabbox --reason implementation prewarm darwin` with that installable. Publish the scoped nix-config change, then deploy from its synchronized primary through `just switch`.
- [ ] Verify the running daemon executable belongs to the new signed closure and record the source revision.

## 4. Live Acceptance and Closure

Files: existing benchmark; if needed create disposable app source in `Tests/Fixtures/`, with bundle and binaries only in `.build/`; record results in this change directory.

- [ ] Warn immediately before focus moves; capture starting app and Space and restore them after the run.
- [ ] Run the existing foreground benchmark. Require same-Space warm p95 <=300 ms and cross-Space <=700 ms.
- [ ] Perform 20 alternating warm Zotero jumps, checking frontmost identity, stable Zotero PID, and no new corrupt-app errors.
- [ ] Cold-launch only the disposable fixture through the production workspace; check the resulting live app identity, then terminate that fixture only.
- [ ] Reconcile spec and plan with actual implementation and evidence, append review/deployment/completion events, and archive through `finishing-a-development-branch` and `closing-loops`.

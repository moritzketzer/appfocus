# AX-less Window Fallback: Native Activation Instead of Reopen

## Problem

ChatGPT's Chromium-based build materializes its main window in the macOS
accessibility tree only while the app is frontmost, so yabai often holds no
AX reference for it (`has-ax-reference: false`, empty role/subrole). Such a
window is invisible to appfocus's eligibility filter, unfocusable via
`yabai -m window --focus`, and untileable. `jump ChatGPT` then takes the
"running but no windows → reopen" path, which surfaces nothing, and the user
cannot switch to the app at all (observed 2026-08-14/15; full diagnosis in
the developing-appfocus gotchas, entry "ChatGPT/Codex main window invisible
to yabai").

## Design

When the confirm query (the fresh dump already taken on the no-eligible-
windows branch) shows the app is running and has at least one **AX-less
candidate** — a window that would pass `isStandardWindow` except for the
missing AX reference (non-sticky, subrole not `AXDialog`/`AXSystemDialog`,
role not `AXHelpTag`, not minimized) — do not reopen. Instead:

1. `focusSpace(candidate.space)` — yabai Space focus needs no window AX.
2. Native app activation via `open -a <app>` (`AppLauncher.activate`), pure
   LaunchServices, no AX.

The user lands on the app (the manual recovery, automated per press). Being
frontmost on its own Space is also what materializes Chromium's AX tree, so
the state tends toward healing. The daemon logs a loud hint that tiling
restoration still needs a warm yabai restart (gotchas recipe).

Predicate lives on `WindowInfo` as `isAXlessCandidate`. First candidate wins
(multiple AX-less windows of one app share the failure mode; any Space of
them is a correct destination).

## Behavior Unchanged

- Apps with zero windows: reopen (running) / launch (not running) as today —
  Finder/Safari flows untouched.
- Sticky-overlay-only apps (e.g. only a Codex dialog): reopen as today.
- No MRU recording for AX-less windows (their ids are unusable as targets).
- Hot path untouched: the fallback lives entirely behind the confirm branch,
  which only runs in the already-broken state.
- Watchdog bounds the fallback like any command; no retry arming (no focus
  target is resolved).
- A truly wedged app (activation ignored): user lands on the candidate's
  Space and nothing raises — no worse than today's silent reopen loop, and
  the log names the state.

## Files

- `Sources/Daemon/Types.swift` — `isAXlessCandidate`.
- `Sources/Daemon/AppLauncher.swift` — protocol + `DefaultAppLauncher.activate`
  (`open -a`, same runner as launch, distinct logging).
- `Sources/Daemon/ActivationLogic.swift` — `confirmNoWindows` computes
  candidates; `handleNoWindows` takes them and branches.
- `Tests/Unit/Mocks.swift` — `MockAppLauncher.activatedApps`.
- `Tests/Unit/ActivationLogicTests.swift` — fallback tests.
- `CLAUDE.md` — one architecture bullet.
- nix-config (deploy commit): overlay bump + gotchas entry update
  ("future lever" → built).

## Verification

- Unit: AX-less candidate → `focusSpace` + `activate`, no reopen, no
  `focusWindow`, no MRU record, pump idle; sticky-only → reopen; zero
  windows → reopen/launch unchanged; full suite green.
- Live after deploy: normal jumps unaffected (`appfocus jump` smoke). The
  broken state itself is not reproducible on demand (ChatGPT currently
  healthy); the fallback path is covered by unit tests and will be observed
  at the next natural recurrence via the new log line.

## Non-Scope

- No automatic yabai restart (WM restart on a keypress is too invasive).
- No cycle-path changes, no config surface, no per-app opt-out.

# Window Model: Read/Act Split for a Query-Free Hot Path

## Problem

Every appfocus keypress runs 2-3 synchronous yabai queries before it can act:
`focusedWindow` (~740 B), `queryAllWindows` (~20 KB), then the focus action.
The queries are exactly the calls that stall when the shared WindowServer is
busy. Hang samples taken during live stalls (2026-08-14,
`~/Library/Logs/appfocus/yabai-hangs.log`) show yabai's `event_loop` worker
thread parked in `mach_msg` inside SkyLight `SLS…` window-list copies, with an
idle main thread: the process waits on WindowServer replies, and appfocus's
queries queue behind everything else loading that single shared server. The
watchdog fired 16 times on 2026-08-14 alone. The resilience shipped in
`ac741bb` makes stalls survivable; this change makes keypresses stop depending
on them.

A second, self-inflicted load source amplifies the stalls. Every yabai
window/app event fans out into 4-8 more `yabai -m query` clients (verified
against the live configs): `window_focused` triggers sketchybar's
`window_state` (2 queries) plus `sync_borders` (2 queries); `window_created`
and friends trigger the spaces.lua `refresh()` (4 queries) plus `sync_borders`;
the `window_destroyed` and `application_terminated` signals run a synchronous
`yabai -m query --windows --space` inline. appfocus's own successful focus
emits `window_focused`, so each jump spawns about 4 extra queries onto the
worker thread it just waited on.

## Driving Characteristic

Responsiveness (keypress-to-focus latency), then resilience under WindowServer
stalls, with testability as a constraint. Fitness function: WATCHDOG fires/day
in `appfocusd.err.log` (baseline 16 on 2026-08-14) must drop, and a unit test
must prove the hot path issues zero yabai queries.

Bookshelf grounding: the design applies DDIA's derived-data pattern (the model
is a materialized view rebuilt by periodic bootstrap), DDIA's per-operation
consistency selection (fresh reads only where staleness costs correctness),
and GoF Observer discipline for the deferred signal-nudge phase
(`stream-processing-designer`, `consistency-model-selector`,
`observer-pattern-implementor`, `architecture-characteristics-identifier`).

## Design

### WindowModel

A new in-memory value owned by the daemon, guarded by a lock:

```swift
struct WindowModel {
    var windows: [WindowInfo]   // full parsed snapshot, all windows
    var focusedId: Int?         // window with has-focus in the snapshot,
                                // overridden by optimistic updates
    var generation: UInt64      // bumped on every rebuild
}
```

As built: `lastRefresh` was dropped in review (unused); `generation` stays
(tested, diagnostic). The optimistic update sets only `focusedId`, not the
stored window's `hasFocus` flag — no consumer reads post-derivation
`hasFocus`, and the semantics are deliberately "the model records the
last-COMPLETED focus action" (a superseded command's late-landing success
really did move OS focus, so the unfenced write tracks reality better; any
disagreement self-heals at the next poll).

`WindowInfo` gains a `hasFocus` field parsed from yabai's `has-focus`. The
snapshot keeps every window (including sticky dialogs); consumers keep
filtering with `isStandardWindow` exactly as today, so the classifier shipped
in `7071549` is unchanged.

### Refresher: FocusPoller grows into the model's bootstrap loop

`FocusPoller` changes from a focus-only poll (`focusedWindow` every 1 s) to a
full-snapshot poll: one `queryAllWindows` every 2 s (config default
`poll_interval_ms` moves from 1000 to 2000). Each completed poll:

1. Rebuilds `WindowModel` (windows + focusedId from `has-focus`).
2. Records MRU state exactly as today: if the snapshot's focused window
   `isStandardWindow`, call `store.recordFocus` with its alias-resolved app.

The existing overlap guard stays: a slow query skips ticks instead of
stacking. A stalled refresh delays only the invisible model update; keypresses
keep reading the last good model. The separate small `focusedWindow` query
disappears from the system: `has-focus` inside the full dump provides it.

As built (review finding F1): `queryAllWindows` completes with an Optional —
`nil` means the query FAILED (backend error/timeout) and callers must not
read it as "no windows"; an empty array is a trustworthy, genuinely
window-less desktop. The poller keeps the last good model on failure but
accepts a genuine empty dump (else ghost windows would stay in the model
forever once the desktop reaches zero windows, dead-ending every jump); the
confirm branch drops the press on failure instead of reopening a duplicate;
the launch poll skips the model rebuild on failure and keeps polling.

Per-operation consistency (the staleness contract):

| Read | Guarantee | Mechanism |
|---|---|---|
| Own focus after own action (cycle/MRU compounding) | read-your-writes | optimistic model update on focus commit |
| Which window of the target app to focus | bounded staleness (≤2 s) | snapshot poll |
| Model shows no windows for a running app | fresh | one live confirm `queryAllWindows` |
| External focus changes feeding MRU | eventual (seconds fine) | snapshot poll |

### Hot path: read the model, issue one action

`ActivationLogic` gains a `model` dependency and stops querying in the common
paths. The pump, watchdog, backoff, cap, and supersession semantics from
`055b2d2`/`ac741bb` are unchanged; only the inside of each job changes:

- **jump, target has windows in the model:** read `model.focusedId` +
  `model.windows` (memory), pick MRU toggle / cycle / best window exactly as
  today, then issue `focusSpace` (if needed) + `focusWindow`. Zero queries.
- **jump, model shows no windows for the app:** run one live
  `queryAllWindows` to confirm before the launch/reopen branch, and rebuild
  the model from its result. A stale empty read here would reopen a second
  window (the `7071549` bug class), so this rare branch pays for a fresh
  read. If the confirm shows windows, proceed on them; if not, launch or
  reopen as today (`pollForWindow` also feeds its results into the model).
- **cycle:** read `model.focusedId`, resolve the app from the model, step the
  ring as today. Zero queries. `model.focusedId == nil` logs
  `cycle: no focused window` and completes.

**Optimistic focus update (read-your-writes):** when `focusWindow(id:)`
reports success, set `model.focusedId = target.id` (and update the stored
window's `hasFocus`). The next queued command in a burst reads the settled
focus without any query, which is what lets serialized `next`/`next`/`next`
and same-app MRU toggles compound one step per press. External focus changes
reconcile at the next poll. On `focusSpace` success the model does not need
updating (Space is read per-window from the snapshot).

**Same-vs-cross-Space rule:** today's semantics, read from the model: skip
`focusSpace` only when the model's focused window is standard and on
`target.space`; otherwise issue `focusSpace` first. Appfocus-driven focus
changes keep the model current via the optimistic update; an external Space
switch can make the skip decision up to one poll interval stale, which under
`workspaces-auto-swoosh=false` would leave the target invisible (gotcha
2026-08-13). Accepted: the race window is ≤2 s, requires an external switch
immediately before a keypress, and self-heals at the next poll or press.

**Membership self-heal:** targets are membership-checked against
`model.windows` (today's pattern against the query result). A vanished id
fails cleanly; the next poll corrects the model.

### One-shot retry of a watchdog-dropped action

Observed failure: a cross-Space Safari jump repeatedly hit the 3 s stall and
was watchdog-dropped while same-Space toggles landed in the gaps; the user had
to re-press. Fix: when the watchdog force-releases a command whose job had
already resolved a concrete focus target, stash `(windowId, space, appName)`
as `pendingRetry`. After `hungBackoff` expires, resubmit it through the normal
`submit` path as a retry job that re-validates the id against the model and
replays only the focus action (never the decision logic, so an
already-recorded MRU toggle cannot double-toggle). Rules:

- One shot: `pendingRetry` clears when the retry is submitted, regardless of
  outcome.
- Any user command submitted before the retry fires cancels it (the user's
  newer intent wins; the existing token supersession already protects
  mid-flight).
- Only focus actions retry. Launch/reopen paths never auto-retry.

### Resilience fold-in

The watchdog now guards a single focus action (plus the rare confirm query
and the launch poll), so a 3 s deadline overrun becomes rare instead of
routine. The token/generation discipline is the same fencing mechanism the
pump already uses; the retry rides it. The fuzz invariant ("pump never
wedges") must additionally cover the retry: a pending retry can never loop or
wedge the pump.

### Deferred (documented, not built now)

- **Signal nudge (change stream):** yabai `signal --add` on structural events
  posting a debounced "dirty" nudge to the daemon socket, triggering an early
  rebuild. Add only if the 2 s staleness produces observed wrong-target
  behavior. The nudge action must itself run zero yabai queries.
- **Native same-Space AX raise:** bypassing yabai for same-Space focus needs
  the CGWindowID-to-AXUIElement mapping via semi-private AX, the exact flaky
  surface that produced the subrole bugs. Revisit only if the single focus
  action still stalls measurably after this change.

## Parallel Track: Cut the Self-Inflicted WindowServer Load (nix-config)

Config-only, out-of-store (`darwin/home/config/yabai/`, live on edit +
`yabai --restart-service`; sketchybar files under
`darwin/home/config/sketchybar/`). Changes:

1. **Debounce helper** `debounce.sh <key> <delay-ms> <cmd...>` in the yabai
   config dir: trailing-edge coalescing via a per-key marker file in
   `$TMPDIR`; a burst of invocations runs the command once after the quiet
   gap.
2. **Sketchybar triggers** (yabairc lines 26-30): route the five per-event
   `--trigger` calls through the debouncer (~200 ms), so a burst of window
   events produces one `windows_on_spaces`/`window_focus` refresh instead of
   one per event (each refresh costs 2-4 yabai queries inside sketchybar).
3. **sync_borders** (11 events): same debouncer, ~150 ms. Each run costs 2
   yabai queries.
4. **Auto-focus signals** (`window_destroyed`, `application_terminated`):
   keep the behavior (focus stack-top visible window when focus is lost) but
   run the body through the debouncer (~200 ms) so a burst of closes runs the
   synchronous `--windows --space` query once, not per event.

Verification: after reload, `yabai -m signal --list` shows the debounced
actions; rapid window churn (open/close loop) produces single deferred
sketchybar refreshes (observable via `sketchybar --query bar` timestamps or
the debouncer's marker files) and no per-event query burst.

## Files

appfocus (worktree `change/window-model`):

- `Sources/Daemon/Types.swift` — `hasFocus` in `WindowInfo` (+ parse).
- `Sources/Daemon/YabaiBackend.swift` — `queryAllWindows` returns the
  unfiltered parsed snapshot (consumers already re-filter with
  `isStandardWindow`); `focusedWindow` stays in the protocol for the hang
  tests but leaves the production paths.
- `Sources/Daemon/WindowModel.swift` — new: model value + thread-safe holder.
- `Sources/Daemon/FocusPoller.swift` — full-snapshot poll, model rebuild,
  MRU recording from snapshot.
- `Sources/Daemon/ActivationLogic.swift` — model-read hot path, confirm-on-
  windowless, optimistic focus update, same/cross-Space rule, one-shot retry.
- `Sources/Daemon/main.swift` — wire the model holder.
- `Sources/Daemon/Config.swift` — `poll_interval_ms` default 2000.
- `Tests/Unit/*` — see Verification.
- `CLAUDE.md` + skill gotchas — document the model and the new defaults.

nix-config (separate repo, normal commit flow):

- `darwin/home/config/yabai/debounce.sh` — new.
- `darwin/home/config/yabai/yabairc` — debounced signal actions.

## Verification

- Unit tests against the existing mocks (extended with call counting for
  `queryAllWindows`):
  - jump with windows in the model issues zero queries and one focus action
    (plus `focusSpace` when crossing Spaces);
  - burst of cycles compounds in order with zero queries (optimistic update);
  - jump with an empty model for a running app issues exactly one confirm
    query and does not reopen when the confirm finds windows;
  - stale target id (in model, gone from backend) fails cleanly and the next
    poll heals the model;
  - watchdog-dropped focus action retries exactly once after backoff, is
    cancelled by an intervening user command, and never retries launch/reopen;
  - fuzz invariant extended: pump never wedges with retries enabled.
- Existing rapid-input, sticky-classifier, and resilience tests stay green
  (rewritten where they currently drive the removed per-command
  `focusedWindow` query, asserting the same behavior through the model).
- `make all && make test` green three consecutive runs.
- Live: deploy, then compare WATCHDOG fires/day and `pump:` latency debug
  lines against the 2026-08-14 baseline. Deploy must also check whether the
  Nix-managed `~/.config/appfocus/config.json` pins `poll_interval_ms` (the
  new 2000 default only applies when the field is unset).

## Non-Scope

- No signal nudge, no native AX raise (deferred; above).
- No change to kanata integration, StateStore persistence format, CLI
  protocol, reopen strategies, or the `isStandardWindow` classifier.
- No sketchybar Lua rewrites; only invocation debouncing in yabairc.

## Baseline Repair (already on this branch)

`origin/main`'s `YabaiBackendTests` hang tests were flaky under the fuzz
test's timer load and self-poisoned via orphaned fixtures; `39e2b7d` fixes
the tests only (serialized suite, 10 s budget, path-scoped pgrep, orphan
reaping, poll-for-death, sliced fixture sleep). No production change.

## Post-Deploy Fixes (2026-08-15, `focus-model-fences`)

Live rapid-switching exposed two defects; reviewer finding F4's "accepted
race" disposition was overturned by production evidence (snapshot queries
measure 90-350 ms under load, so a poll straddling a focus action is routine):

1. `replaceSnapshot` now takes `queryStartedAt` and fences: an optimistic
   focus newer than the query's start wins, and a mid-transition dump with no
   `has-focus` row keeps the prior focus while its window exists (clears when
   gone, preserving the empty-desktop wipe). The poller stamps its query
   start; the confirm/launch-poll rebuilds pass nil (their dumps cannot be
   staler than the last optimistic update under pump serialization).
2. A failed `focusSpace` (yabai refuses to focus the already-focused Space)
   no longer aborts the jump — it logs and continues to the window focus.
   The genuine-failure case degrades to invisible AX focus corrected at the
   next poll instead of a dead press.

Known incoherence, accepted: the poller records MRU from the raw dump's
`has-focus` row, not the fenced `focusedId`, so a straddling dump can
transiently flip an app's prev/last pair; `performJump` re-records the fenced
focus before any MRU decision, so it self-corrects.

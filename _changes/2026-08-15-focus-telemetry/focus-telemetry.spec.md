# Focus Telemetry: Measure Whether Switching Actually Works

## Problem

Three deploys of switching changes were validated by unit tests, log reading,
and one-off manual probes — and the lived experience still disagreed twice.
Unit tests prove the decision logic against a mocked yabai; nothing measures
the real chain (kanata → daemon → yabai → WindowServer → visible focus).
There is no number that says whether a press reached the intended window, how
long it took, or how often it fails. "Verified" and "buggy" can coexist
because verification never observed the outcome the user experiences.

## Goal

Two instruments and one definition:

1. **Outcome telemetry in the daemon** — every command produces one
   structured record: what was intended, what the daemon decided, what
   actually happened on screen, and how long each phase took. Continuous
   ground truth from real usage.
2. **End-to-end benchmark harness** — a script that drives the real daemon
   through the real socket and asserts real visible focus via yabai, as the
   deploy gate that has been missing.
3. **Definition of "works"** — numeric thresholds the telemetry and
   benchmark check, so pass/fail stops being vibes.

Explicit non-goal: this change alters NO switching behavior. Pure
observability plus harness. Whatever the numbers indict gets fixed in a
separate change, re-benchmarked.

## Part 1: Outcome Telemetry

### Command trace

Each submitted command carries a `CommandTrace` through its chain:

```swift
struct CommandTrace {
    let command: String        // "jump" | "next" | "prev"
    let app: String?           // resolved target app (nil for cycle at entry)
    var path: String           // "hot" | "confirm" | "launch" | "reopen"
                               //   | "fallback" | "retry" | "noop"
    var targetWindowId: Int?   // resolved focus target, when one exists
    var targetSpace: Int?
    var crossedSpace: Bool     // whether a focusSpace was issued — the
                               // same-vs-cross-Space split in stats
    let receivedAt: DispatchTime
    var decidedAt: DispatchTime?    // target resolved / branch chosen
    var actionedAt: DispatchTime?   // last backend action completed
    var outcome: String             // see taxonomy
    var detail: String?             // forensics on non-ok outcomes
}
```

`ActivationLogic` creates the trace at `submit`, enriches it along the
existing paths (no behavior change — assignments only), and hands it to the
verifier at `finish`. Commands that never run still produce records:
`dropped-backoff` (circuit breaker), `dropped-cap` (queue cap),
`superseded` (last-write-wins), `timeout` (watchdog fired).

### Outcome verification

A new `OutcomeVerifier` (owns its own queue, never touches the pump):

- On command completion it schedules one verification read ~350 ms later:
  a single `queryAllWindows` dump. From it: the focused window, whether it
  `is-visible`, and its Space.
- The dump is also fed into the `WindowModelStore` via the fenced
  `replaceSnapshot` — verification doubles as a fresh post-switch model
  rebuild, so it partially pays for its own query cost.
- **Burst coalescing:** at most one verification is pending at a time. A
  newer completed command replaces the pending one; the replaced command's
  record is finalized with `outcome: "unverified-burst"` (its timing phases
  are still recorded). During rapid switching only the final press of a
  burst gets a verification read — no query storm.
- If the verification query fails (nil), outcome is `unverified-queryfail`.

### Outcome taxonomy

| Outcome | Meaning |
|---|---|
| `ok` | intended window focused AND visible |
| `ok-app` | intended app frontmost, different window than predicted (launch/reopen/fallback paths where no window id was resolvable, or MRU landed elsewhere) |
| `invisible` | intended window has focus but `is-visible` false — the swoosh-off failure mode |
| `wrong-window` | something else focused |
| `failed` | a backend action reported failure |
| `noop` | correct no-op (single-window MRU, empty ring) — classified at decision time, no verification read (nothing was actioned) |
| `superseded` / `dropped-backoff` / `dropped-cap` / `timeout` | never completed; recorded at the site |
| `unverified-burst` / `unverified-queryfail` | completed, verification skipped/failed |

Non-ok records append forensics into `detail`: model generation and
focused-id at decision time, chosen branch, target vs. actual
window/space, and whether a poller rebuild happened between decision and
verification.

### Record sink

- JSONL, one line per command:
  `~/.local/state/appfocus/telemetry.jsonl`.
- Fields: ISO timestamp, command, app, path, target id/space, phase
  durations in ms (`decide`, `act`, `verify`, `total`), outcome, detail.
- Rotation: when the file exceeds 5 MB at daemon start or write time,
  rename to `telemetry.jsonl.1` (single generation kept). No timers, no
  daemons.
- Failure to write telemetry never affects command processing (best-effort,
  errors logged once).

### `appfocus stats`

New CLI subcommand, entirely client-side (reads the JSONL, no daemon
protocol change):

```
appfocus stats [--since 2h|30m|1d]
```

Prints: total commands; success rate (`ok`+`ok-app`+`noop` over decided
commands); outcome counts by taxonomy; p50/p95 `total` latency split by
path (`hot` vs `confirm` vs others) and by same-Space vs cross-Space; the
last 10 non-ok records with forensics. This is the number that answers
"does it work".

## Part 2: Benchmark Harness

`bench/appfocus-bench.sh` in the repo (bash + jq, run from a checkout;
not installed system-wide). Drives the real daemon via the `appfocus` CLI
socket; observes ground truth by polling `yabai -m query` every 50 ms (up
to 2 s per trial) until the intended window is focused and visible.

- **Setup:** auto-discovers targets from live yabai state — two apps with
  standard windows on different Spaces, plus a Space-1 target when one
  exists; overridable via arguments. Records the initially focused window
  and restores it at the end.
- **Scenarios:**
  1. same-Space jump ×10
  2. cross-Space jump ×10
  3. jump to the Space-1 target ×10
  4. rapid alternation A↔B ×20 (120 ms cadence) — asserts the final state
     and, via telemetry records, that every press resolved to an accepted
     outcome (`ok`/`ok-app`/`superseded`; zero `dropped-*`, zero `failed`)
  5. cycle burst ×12 within one app — asserts the deterministic end window
     given the ring, plus per-press outcomes
  6. control: 10 jumps while the poller runs normally (no special setup —
     covers straddle behavior)
- **Report:** per-scenario success x/y, latency p50/p95, every failure with
  the yabai state at failure time; cross-checks its external observations
  against the daemon's telemetry records for the same window of time and
  flags disagreement (two independent ground truths).
- **Exit code:** nonzero when thresholds (below) are violated → usable as a
  deploy gate.
- **Side effect warning:** a run visibly moves focus for ~60–90 s. Run on
  demand only, never scheduled.

## Part 3: Definition of "Works"

Checked by both instruments:

- **Reliability:** ≥ 99% of decided presses end `ok`/`ok-app`/`noop`
  (telemetry, rolling); benchmark: zero failures across its ~60 trials.
- **Latency:** p95 press-to-visible ≤ 300 ms same-Space, ≤ 700 ms
  cross-Space (benchmark external measurement; telemetry `total` as the
  continuous proxy).
- **No dead presses:** zero `dropped-*`/`failed`/`invisible` outcomes in
  normal operation (stall periods excepted — `dropped-backoff` during a
  genuine yabai hang is the designed degradation and reported as such).

The current deployed build gets benchmarked FIRST to produce the baseline;
fixes then argue against these numbers, not vibes. The per-phase timings
also adjudicate an open question honestly: if `act` (yabai's own
`window --focus`, measured 195–350 ms in earlier smokes) dominates, the
remaining sluggishness is yabai/WindowServer-side, not daemon-side — a
different fix track than another daemon change.

## Files

- `Sources/Daemon/CommandTrace.swift` — new: trace struct + JSONL encoding.
- `Sources/Daemon/OutcomeVerifier.swift` — new: verification scheduling,
  coalescing, sink, rotation.
- `Sources/Daemon/ActivationLogic.swift` — trace creation/enrichment at the
  existing sites (assignments only; no control-flow change).
- `Sources/Daemon/main.swift` — wire verifier.
- `Sources/CLI/main.swift` + `Sources/Common/` — `stats` subcommand
  (client-side JSONL analysis; no wire-protocol change).
- `Tests/Unit/OutcomeVerifierTests.swift`, trace tests, stats-parsing
  tests; existing suite untouched semantically.
- `bench/appfocus-bench.sh` — new.
- `CLAUDE.md`, gotchas — document telemetry, stats, bench.
- nix-config (deploy): overlay bump only.

## Verification of This Change Itself

- Unit: verifier coalescing (burst → one verification, earlier records
  `unverified-burst`); outcome classification per taxonomy from synthetic
  dumps; rotation; trace enrichment on each path (hot/confirm/launch/
  reopen/fallback/noop/dropped/superseded/timeout); stats aggregation from
  a fixture JSONL; full suite green — and zero behavior change asserted by
  the untouched existing tests.
- Live: deploy, use the switcher normally for a bit, `appfocus stats`
  shows sane records; then one attended benchmark run for the baseline.

## Non-Scope

- No switching-behavior changes, no threshold-triggered automation, no
  scheduled benchmark runs, no dashboards, no VPS/Hermes integration.
- No kanata-side keypress timestamping (receipt-at-daemon is the start of
  what appfocus can own; input-to-daemon latency is measurable separately
  if the numbers ever point there).

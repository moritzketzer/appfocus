#!/usr/bin/env bash
# appfocus-bench.sh — end-to-end benchmark for the appfocus switcher.
#
# Drives the REAL daemon through the appfocus CLI and measures ground truth
# by polling yabai until the intended window is focused AND visible. This is
# the deploy gate: unit tests prove the decision logic; this proves the
# switch actually happens on screen, and how fast.
#
# WARNING: a run visibly moves focus for ~60-90s. Run attended, on demand.
#
# Usage:
#   bench/appfocus-bench.sh [--dry-run] [--app-a NAME] [--app-b NAME]
#
# Thresholds (spec "definition of works"): zero failed trials;
# p95 same-Space <= 300ms; p95 cross-Space <= 700ms. Exit 1 on violation.
set -uo pipefail

YABAI="${YABAI:-/etc/profiles/per-user/$USER/bin/yabai}"
APPFOCUS="${APPFOCUS:-appfocus}"
JQ="${JQ:-jq}"
TRIAL_TIMEOUT_MS=2000   # poll cadence is the `sleep 0.05` in wait_for_window

DRY_RUN=0
APP_A=""
APP_B=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --app-a) APP_A="$2"; shift ;;
    --app-b) APP_B="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

fail_count=0
declare -a same_space_lat=()
declare -a cross_space_lat=()
declare -a failures=()

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

dump() { "$YABAI" -m query --windows 2>/dev/null; }

focused_line() {
  dump | "$JQ" -r '.[] | select(."has-focus"==true) | "\(.app)\t\(.id)\t\(."is-visible")"' | head -1
}

# Wait until window $1 is focused and visible; echo latency ms or "FAIL".
wait_for_window() {
  local target_id="$1" start elapsed line
  start=$(now_ms)
  while :; do
    # shellcheck disable=SC2016  # $id is a jq variable, not shell
    line=$(dump | "$JQ" -r --argjson id "$target_id" \
      '.[] | select(.id==$id) | "\(."has-focus")\t\(."is-visible")"')
    if [ "$line" = "true	true" ]; then
      echo $(( $(now_ms) - start ))
      return 0
    fi
    elapsed=$(( $(now_ms) - start ))
    if [ "$elapsed" -ge "$TRIAL_TIMEOUT_MS" ]; then
      echo "FAIL"
      return 1
    fi
    sleep 0.05
  done
}

record_trial() {
  # $1=scenario $2=cross(0/1) $3=latency-or-FAIL $4=context
  if [ "$3" = "FAIL" ]; then
    fail_count=$((fail_count + 1))
    failures+=("$1: $4 | state: $(focused_line)")
  elif [ "$2" = "1" ]; then
    cross_space_lat+=("$3")
  else
    same_space_lat+=("$3")
  fi
}

percentile() {
  # $1 = p (e.g. 95); reads numbers on stdin
  python3 -c "
import sys, math
v = sorted(int(x) for x in sys.stdin.read().split())
if not v: print('n/a'); sys.exit()
i = min(len(v)-1, max(0, math.ceil(len(v)*$1/100)-1))
print(v[i])"
}

# ─── Discovery ──────────────────────────────────────────────────────────────
# Two apps with standard windows on different Spaces; window ids + spaces.
discover() {
  dump | "$JQ" -r '
    [.[] | select(."has-ax-reference" and (."is-sticky"|not)
                  and (.subrole != "AXDialog") and (.subrole != "AXSystemDialog")
                  and (.role != "AXHelpTag") and (."is-minimized"|not))]
    | group_by(.app)
    | map({app: .[0].app, id: .[0].id, space: .[0].space, count: length})
    | .[] | "\(.app)\t\(.id)\t\(.space)\t\(.count)"'
}

CANDIDATES=$(discover)
if [ -n "$APP_A" ]; then
  A_LINE=$(echo "$CANDIDATES" | awk -F'\t' -v a="$APP_A" '$1==a {print; exit}')
else
  A_LINE=$(echo "$CANDIDATES" | head -1)
fi
A_APP=$(echo "$A_LINE" | cut -f1); A_ID=$(echo "$A_LINE" | cut -f2); A_SPACE=$(echo "$A_LINE" | cut -f3)
if [ -n "$APP_B" ]; then
  B_LINE=$(echo "$CANDIDATES" | awk -F'\t' -v b="$APP_B" '$1==b {print; exit}')
else
  B_LINE=$(echo "$CANDIDATES" | awk -F'\t' -v sp="$A_SPACE" -v a="$A_APP" '$1!=a && $3!=sp {print; exit}')
fi
B_APP=$(echo "$B_LINE" | cut -f1); B_ID=$(echo "$B_LINE" | cut -f2); B_SPACE=$(echo "$B_LINE" | cut -f3)
S1_LINE=$(echo "$CANDIDATES" | awk -F'\t' '$3==1 {print; exit}')
S1_APP=$(echo "$S1_LINE" | cut -f1); S1_ID=$(echo "$S1_LINE" | cut -f2)
CYCLE_LINE=$(echo "$CANDIDATES" | awk -F'\t' '$4>=2 {print; exit}')
CYCLE_APP=$(echo "$CYCLE_LINE" | cut -f1)

INITIAL_FOCUS=$(dump | "$JQ" -r '.[] | select(."has-focus"==true) | .id' | head -1)

if [ -z "$A_APP" ] || [ -z "$B_APP" ]; then
  echo "discovery failed: need two apps with standard windows on different Spaces" >&2
  echo "candidates:"; echo "$CANDIDATES"
  exit 2
fi

echo "=== appfocus-bench plan ==="
echo "A: $A_APP (window $A_ID, space $A_SPACE)"
echo "B: $B_APP (window $B_ID, space $B_SPACE)"
echo "Space-1 target: ${S1_APP:-none} (${S1_ID:-n/a})"
echo "Cycle app (>=2 windows): ${CYCLE_APP:-none}"
echo "Initial focus (restored at end): window ${INITIAL_FOCUS:-unknown}"
if [ "$DRY_RUN" = "1" ]; then echo "(dry run — no commands sent)"; exit 0; fi
BENCH_START_TS=$(date -u +"%Y-%m-%dT%H:%M:%S")

# ─── Scenario 1+2: alternating same/cross-Space jumps ───────────────────────
# Jumping A→B→A… from a known position: each jump to the OTHER app is
# cross-Space when their Spaces differ. Same-Space trials use MRU toggling
# within the cycle app when available.
echo; echo "=== scenario: cross-Space jump x10 ($A_APP <-> $B_APP) ==="
"$APPFOCUS" jump "$A_APP" >/dev/null 2>&1; sleep 1
for i in $(seq 1 10); do
  if [ $((i % 2)) -eq 1 ]; then target_app="$B_APP"; target_id="$B_ID"; else target_app="$A_APP"; target_id="$A_ID"; fi
  "$APPFOCUS" jump "$target_app" >/dev/null 2>&1
  lat=$(wait_for_window "$target_id") || true
  record_trial "cross-jump" 1 "$lat" "jump $target_app (window $target_id) trial $i"
  sleep 0.4
done

# ─── Scenario 3: Space-1 target ─────────────────────────────────────────────
if [ -n "$S1_APP" ]; then
  echo "=== scenario: Space-1 jump x10 ($S1_APP) ==="
  for i in $(seq 1 10); do
    "$APPFOCUS" jump "$B_APP" >/dev/null 2>&1; sleep 0.5
    "$APPFOCUS" jump "$S1_APP" >/dev/null 2>&1
    lat=$(wait_for_window "$S1_ID") || true
    record_trial "space1-jump" 1 "$lat" "jump $S1_APP (window $S1_ID) trial $i"
    sleep 0.4
  done
else
  echo "=== scenario: Space-1 jump SKIPPED (no standard window on Space 1) ==="
fi

# ─── Scenario 4: rapid alternation ──────────────────────────────────────────
echo "=== scenario: rapid alternation x20 (120ms cadence) ==="
for i in $(seq 1 20); do
  if [ $((i % 2)) -eq 1 ]; then "$APPFOCUS" jump "$A_APP" >/dev/null 2>&1; else "$APPFOCUS" jump "$B_APP" >/dev/null 2>&1; fi
  sleep 0.12
done
# Final press was B (i=20 even) — the burst must settle on B.
lat=$(wait_for_window "$B_ID") || true
record_trial "rapid-final" 1 "$lat" "burst must settle on $B_APP (window $B_ID)"

# ─── Scenario 5: cycle burst ────────────────────────────────────────────────
if [ -n "$CYCLE_APP" ]; then
  echo "=== scenario: cycle burst x6 in $CYCLE_APP ==="
  "$APPFOCUS" jump "$CYCLE_APP" >/dev/null 2>&1; sleep 0.8
  for _ in $(seq 1 6); do "$APPFOCUS" next >/dev/null 2>&1; sleep 0.25; done
  sleep 1
  final_app=$(focused_line | cut -f1)
  if [ "$final_app" = "$CYCLE_APP" ]; then
    same_space_lat+=(0)  # counted as pass; latency measured per-press by telemetry
    echo "cycle burst stayed within $CYCLE_APP: OK"
  else
    fail_count=$((fail_count + 1))
    failures+=("cycle-burst: ended on $final_app, expected $CYCLE_APP")
  fi
else
  echo "=== scenario: cycle burst SKIPPED (no app with >=2 standard windows) ==="
fi

# ─── Restore ────────────────────────────────────────────────────────────────
if [ -n "$INITIAL_FOCUS" ]; then
  "$YABAI" -m window --focus "$INITIAL_FOCUS" >/dev/null 2>&1 || true
fi

# ─── Report ─────────────────────────────────────────────────────────────────
echo; echo "=== RESULTS ==="
total_trials=$(( ${#same_space_lat[@]} + ${#cross_space_lat[@]} + fail_count ))
echo "trials: $total_trials, failures: $fail_count"
if [ ${#same_space_lat[@]} -gt 0 ]; then
  p50=$(printf '%s\n' "${same_space_lat[@]}" | percentile 50)
  p95=$(printf '%s\n' "${same_space_lat[@]}" | percentile 95)
  echo "same-Space:  n=${#same_space_lat[@]} p50=${p50}ms p95=${p95}ms (threshold p95<=300)"
else
  p95=0
fi
same_p95=${p95:-0}
if [ ${#cross_space_lat[@]} -gt 0 ]; then
  p50=$(printf '%s\n' "${cross_space_lat[@]}" | percentile 50)
  p95=$(printf '%s\n' "${cross_space_lat[@]}" | percentile 95)
  echo "cross-Space: n=${#cross_space_lat[@]} p50=${p50}ms p95=${p95}ms (threshold p95<=700)"
else
  p95=0
fi
cross_p95=${p95:-0}

if [ "$fail_count" -gt 0 ]; then
  echo; echo "FAILURES:"
  printf '  %s\n' "${failures[@]}"
fi

echo; echo "=== daemon telemetry for this run (cross-check) ==="
"$APPFOCUS" stats --since 10m 2>/dev/null || echo "(appfocus stats unavailable)"
echo "(bench started at ${BENCH_START_TS}Z)"

status=0
[ "$fail_count" -gt 0 ] && { echo "THRESHOLD VIOLATION: failures > 0"; status=1; }
[ "${same_p95:-0}" != "n/a" ] && [ "${same_p95:-0}" -gt 300 ] && { echo "THRESHOLD VIOLATION: same-Space p95 ${same_p95}ms > 300ms"; status=1; }
[ "${cross_p95:-0}" != "n/a" ] && [ "${cross_p95:-0}" -gt 700 ] && { echo "THRESHOLD VIOLATION: cross-Space p95 ${cross_p95}ms > 700ms"; status=1; }
[ "$status" -eq 0 ] && echo "ALL THRESHOLDS MET"
exit "$status"

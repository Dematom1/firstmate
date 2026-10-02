#!/usr/bin/env bash
# tests/fm-wake-drain-large-log-perf.test.sh - a large status log must fold
# correctly AND drain quickly. The incident this pins: the drain's presentation
# path forked external commands per status line and per task per section, so a
# home with a multi-thousand-line status log paid minutes per drain on a loaded
# machine. The drain must stay single-pass-per-section over external processes:
# keyed open/resolved folding, the unread surface, and pause/blocked semantics
# are asserted on the same large log that carries the time bound.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-large-log-perf-tests)

# Supervision-host detection and guard liveness are orthogonal to this suite;
# keep both inert so the time bound measures presentation, not detection.
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

LARGE_LINES=4000
# Generous: the bound exists to catch a fork-per-line regression (minutes on a
# loaded machine), not to measure the test machine. A quiet drain of the large
# log finishes in seconds; anything past this bound is the regression.
DRAIN_TIME_BOUND_SECS=60

make_large_log_state() {
  local state=$1 i
  mkdir -p "$state"
  # kind=secondmate, like a real long-lived routed task log: a ship's done line
  # closes every open decision (fold version 6), so a ship log this full of
  # terminal lines could not carry an old open decision at all.
  {
    # One open decision the fold must keep across the whole log, opened first
    # so only the cursor-backed fold's carried-open-set can still see it.
    printf 'needs-decision [key=buried-open]: the buried decision stays open\n'
    i=1
    while [ "$i" -le "$LARGE_LINES" ]; do
      case $((i % 7)) in
        0) printf 'working [corr=%016x]: progress line %d with enough prose to be a realistic width for a busy status log\n' "$i" "$i" ;;
        1) printf 'note: informational line %d\n' "$i" ;;
        2) printf 'done [key=closed-%d]: finished unit %d\n' "$i" "$i" ;;
        3) printf 'resolved [key=closed-%d]: closed unit %d\n' "$i" "$i" ;;
        4) printf 'paused: external wait %d\n' "$i" ;;
        5) printf 'blocked [key=probe-%d]: blocked on unit %d\n' "$i" "$i" ;;
        6) printf 'resolved [key=probe-%d]: unblocked unit %d\n' "$((i - 1))" "$i" ;;
      esac
      i=$((i + 1))
    done
  } > "$state/large.status"
  printf 'kind=secondmate\n' > "$state/large.meta"
  # A small neighbor task so the fleet-wide scans fold more than one log.
  printf 'working: on it\nblocked [key=neighbor]: neighbor blocked\n' > "$state/neighbor.status"
  printf 'kind=secondmate\n' > "$state/neighbor.meta"
}

test_large_log_folds_correctly_and_quickly() {
  local dir state out first_secs second_secs
  dir=$(make_case large-log)
  state="$dir/state"
  out="$dir/drain.out"
  make_large_log_state "$state"

  first_secs=$(fm_epoch_now)
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "drain failed on the large synthetic log"
  second_secs=$(fm_epoch_now)
  [ $((second_secs - first_secs)) -le "$DRAIN_TIME_BOUND_SECS" ] \
    || fail "the large-log drain took $((second_secs - first_secs))s (bound ${DRAIN_TIME_BOUND_SECS}s) - the fork-per-line regression is back"

  grep -F 'large [key=buried-open] needs-decision: the buried decision stays open' "$out" >/dev/null \
    || fail "the decision opened before 4000 routine lines was not still open after them"
  grep -F 'neighbor [key=neighbor] blocked:' "$out" >/dev/null \
    || fail "the neighbor task's open decision was not surfaced"
  if grep -F '[key=probe-' "$out" >/dev/null; then
    fail "a blocked key resolved by the next line was reported open"
  fi

  # The second drain runs on the cursor-backed steady state (nothing new since
  # the first drain), the shape every quiet fleet heartbeat pays.
  first_secs=$(fm_epoch_now)
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "second drain failed on the large synthetic log"
  second_secs=$(fm_epoch_now)
  [ $((second_secs - first_secs)) -le "$DRAIN_TIME_BOUND_SECS" ] \
    || fail "the steady-state large-log drain took $((second_secs - first_secs))s (bound ${DRAIN_TIME_BOUND_SECS}s)"

  grep -F 'large [key=buried-open] needs-decision:' "$out" >/dev/null \
    || fail "the steady-state drain dropped the still-open buried decision"
  pass "a ${LARGE_LINES}-line status log folds correctly and drains inside the time bound, twice"
}

test_drain_leaves_no_scratch_files_and_harness_memo_is_honored() {
  local dir state leftover
  dir=$(make_case scratch-cleanup)
  state="$dir/state"
  make_large_log_state "$state"
  printf 'working: more\n' >> "$state/neighbor.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 \
    || fail "drain failed on the scratch-cleanup state"
  leftover=$(find "$state" -maxdepth 1 \( -name '.*.read.*' -o -name '.*.unread.*' -o -name '.*.span.*' \) -print)
  [ -z "$leftover" ] || fail "the drain left span scratch files behind: $leftover"
  [ "$(FM_HARNESS_MEMO=codex "$ROOT/bin/fm-harness.sh")" = codex ] \
    || fail "a memoized harness was not served without re-detection"
  pass "the drain removes its deferred span scratch files and serves a memoized harness"
}

# Seconds-since-epoch without assuming a GNU date: bash's printf %(...)T when
# available, date otherwise (tests/lib.sh owns no clock helper).
fm_epoch_now() {
  if printf '%(%s)T' -1 2>/dev/null; then return; fi
  date +%s
}

test_large_log_folds_correctly_and_quickly
test_drain_leaves_no_scratch_files_and_harness_memo_is_honored

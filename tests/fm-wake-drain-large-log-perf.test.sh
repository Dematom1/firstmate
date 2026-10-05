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

  local copy="$dir/bin-copy" execs
  cp -R "$ROOT/bin" "$copy"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nif [ -n "${FM_HARNESS_MEMO:-}" ]; then echo "$FM_HARNESS_MEMO"; exit 0; fi\necho x >> "%s/harness.execs"\necho codex\n' "$dir" > "$copy/fm-harness.sh"
  chmod +x "$copy/fm-harness.sh"
  rm -rf "$state"; make_large_log_state "$state"
  rm -f "$state"/.*.open-decisions-cursor
  env -u FM_HARNESS_MEMO -u FM_TEST_SEAM FM_STATE_OVERRIDE="$state" "$copy/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "drain with a counting harness stub failed"
  execs=$(wc -l < "$dir/harness.execs" 2>/dev/null | tr -d ' ')
  [ "${execs:-0}" = 1 ] || fail "the drain ran harness detection ${execs:-0} times, expected exactly once"
  pass "the drain removes its deferred span scratch files and serves a memoized harness"
}

make_prefetch_state() {
  local state=$1 i
  mkdir -p "$state"
  for i in 1 2 3; do
    printf 'note: first %s\n' "$i" > "$state/t$i.status"
    printf 'kind=secondmate\n' > "$state/t$i.meta"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "seed drain failed"
  for i in 1 2 3; do
    printf 'note: second %s\n' "$i" >> "$state/t$i.status"
  done
  i=0
  while [ "$i" -lt 1500 ]; do
    printf 'note: bulk line %s with enough padding to push this tail span past sixty-four kibibytes\n' "$i" >> "$state/t2.status"
    i=$((i + 1))
  done
  printf 'working: routine tail\n' >> "$state/t3.status"
  printf 'needs-decision [key=od-1]: first open decision\n' >> "$state/t1.status"
  printf 'blocked [key=od-3]: second open decision\n' >> "$state/t3.status"
}

test_batched_span_prefetch_matches_the_per_file_reader() {
  local dir state_a state_b reader
  dir=$(make_case batched-prefetch)
  state_a="$dir/state-a"
  state_b="$dir/state-b"
  make_prefetch_state "$state_a"
  make_prefetch_state "$state_b"
  reader="$dir/reader.sh"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nperl -e '"'"'open my $f, "<", $ARGV[0] or exit 1; binmode $f; seek($f, $ARGV[1], 0); read($f, my $b, $ARGV[2]); print $b'"'"' "$@"\n' > "$reader"
  chmod +x "$reader"
  FM_STATE_OVERRIDE="$state_a" "$DRAIN" > "$dir/batched.out" 2>/dev/null || fail "batched drain failed"
  FM_STATE_OVERRIDE="$state_b" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$dir/plain.out" 2>/dev/null || fail "per-file drain failed"
  grep -F 'second 1' "$dir/batched.out" >/dev/null || fail "the batched drain did not present the unread note"
  grep -F 'bulk line 1499' "$dir/batched.out" >/dev/null || fail "the batched drain lost the over-64KiB tail"
  grep -F 'od-1' "$dir/batched.out" >/dev/null || fail "the batched drain lost an open decision"
  grep -F 'od-3' "$dir/batched.out" >/dev/null || fail "the batched drain lost an open decision"
  cmp -s "$dir/batched.out" "$dir/plain.out" || { diff "$dir/batched.out" "$dir/plain.out" | head -10 >&2; fail "the batched drain output differs from the per-file reader's"; }
  [ -z "$(find "$state_a" -maxdepth 1 \( -name '.*.read.*' -o -name '.*.unread.*' -o -name '.*.span.*' \) -print)" ] \
    || fail "the batched drain left scratch files behind"
  pass "a multi-task drain with an over-64KiB tail matches the per-file reader and leaves no scratch"
}

test_broken_status_symlink_does_not_hide_healthy_tasks() {
  local dir state
  dir=$(make_case broken-symlink)
  state="$dir/state"
  mkdir -p "$state"
  printf 'note: bootstrap\n' > "$state/healthy.status"
  printf 'kind=secondmate\n' > "$state/healthy.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "seed drain failed"
  ln -s "$dir/does-not-exist" "$state/broken.status"
  printf 'note: surfaced beside a broken symlink\n' >> "$state/healthy.status"
  printf 'needs-decision [key=od-sym]: open beside a broken symlink\n' >> "$state/healthy.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2>/dev/null || fail "drain failed beside a broken symlink"
  grep -F 'surfaced beside a broken symlink' "$dir/out" >/dev/null || fail "unread status was hidden by a broken status symlink"
  grep -F 'od-sym' "$dir/out" >/dev/null || fail "an open decision was hidden by a broken status symlink"
  grep -F 'INCOMPLETE' "$dir/out" >/dev/null && fail "a broken status symlink made presentation incomplete"
  pass "a broken status symlink does not hide healthy tasks' unread status or open decisions"
}

test_primary_pin_outranks_the_harness_memo() {
  local out
  out=$(env FM_HARNESS_MEMO=codex FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=claude "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "the memo overrode the supervision primary pin (got '$out')"
  pass "the supervision primary pin outranks an inherited harness memo"
}

test_unreadable_presentation_manifest_is_incomplete_not_replayed() {
  local dir state
  dir=$(make_case unreadable-manifest)
  state="$dir/state"
  mkdir -p "$state"
  printf 'note: already presented line\n' > "$state/t.status"
  printf 'kind=secondmate\n' > "$state/t.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "seed drain failed"
  [ -e "$state/.status-presentation-cursor" ] || fail "seed drain wrote no presentation cursor"
  chmod 000 "$state/.status-presentation-cursor"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2>/dev/null
  chmod 600 "$state/.status-presentation-cursor"
  grep -F 'STATUS PRESENTATION INCOMPLETE' "$dir/out" >/dev/null || fail "an unreadable presentation cursor was not reported incomplete"
  grep -F 'already presented line' "$dir/out" >/dev/null && fail "an unreadable presentation cursor replayed presented status"
  pass "an unreadable presentation manifest fails presentation as incomplete without replaying status"
}

# Seconds-since-epoch without assuming a GNU date: bash's printf %(...)T when
# available, date otherwise (tests/lib.sh owns no clock helper).
fm_epoch_now() {
  if printf '%(%s)T' -1 2>/dev/null; then return; fi
  date +%s
}

test_large_log_folds_correctly_and_quickly
test_drain_leaves_no_scratch_files_and_harness_memo_is_honored
test_batched_span_prefetch_matches_the_per_file_reader
test_broken_status_symlink_does_not_hide_healthy_tasks
test_primary_pin_outranks_the_harness_memo
test_unreadable_presentation_manifest_is_incomplete_not_replayed

#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lablib.sh"
CODE_HEAD=/Users/laszlohoranszky/.no-mistakes/worktrees/cefde73f9e93/01M6CHFYY73HWAK8A41B7K47WQ
lab_init "$CODE_HEAD" pause-ceiling || exit 1
mkdir -p "$LIVE_DIR/out"
ST="$LABH/state"
now=$(date +%s)
past_until=$(date -u -r "$((now - 300))" '+%Y-%m-%dT%H:%M:%SZ')
lab_env tmux -f /dev/null new-session -d -s lab -n boot -x 160 -y 40 -c "$ROOT"
seed() {
  local t=$1 pause=$2 age=$3
  mkdir -p "$ROOT/wt-$t"
  lab_env tmux new-window -d -t lab: -n "fm-$t" -c "$ROOT/wt-$t" "env -i HOME=$ROOT PATH=/usr/bin:/bin PS1='idle-worker\$ ' bash --norc --noprofile"
  printf 'window=lab:fm-%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\nproject=%s\nmode=no-mistakes\n' "$t" "$ROOT/wt-$t" "$ROOT/wt-$t" > "$ST/$t.meta"
  printf 'working [at=%s]: started\npaused [at=%s]: %s\n' $((now-age-100)) $((now-age)) "$pause" > "$ST/$t.status"
  [ "$age" -gt 0 ] && set_mtime_ago "$ST/$t.status" "$age"
}
seed dated "waiting for the vendor fix until $past_until" 300
seed undated 'waiting for the upstream tool release' 0
seed malformed 'waiting for the vendor fix until tomorrow morning' 300
sleep 1
log "worker panes before: $(lab_env tmux list-panes -a -F '#{window_name}:#{pane_dead}' | tr '\n' ' ')"
KN=(FM_PAUSE_UNDATED_MAX_SECS=90 FM_PAUSE_RESURFACE_SECS=90 FM_POLL=2 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_LIVE=0)
log "env knobs: ${KN[*]}"
log "seeded real watcher source head: $(git -C "$CODE" rev-parse HEAD)"
for t in dated undated malformed; do log "seed $t: $(tail -n 1 "$ST/$t.status")"; done
open_decisions() { lab_env bash -c ". '$CODE/bin/fm-classify-lib.sh'; status_open_decisions '$ST/$1.status'" 2>&1; }
undated_start=$(date +%s)
log '=== watcher runs below the undated 90s age bound'
watch_cycle 60 "${KN[@]}" || true
drain_ack
undated_age=$(( $(date +%s) - undated_start ))
[ "$undated_age" -lt 90 ] || { log "FAIL: initial undated observation was already overdue (${undated_age}s)"; exit 1; }
[ "$(grep -cF 'blocked [key=paused-overdue-undated]' "$ST/undated.status" || true)" -eq 0 ] || exit 1
log "undated pre-bound check at ${undated_age}s: no overdue decision"
wait_until=$((undated_start + 91))
while [ "$(date +%s)" -lt "$wait_until" ]; do sleep 1; done
log '=== watcher cycles through the overdue bound; dated and undated should open once'
end=$(( $(date +%s) + 210 ))
while [ "$(date +%s)" -lt "$end" ]; do
  left=$(( end - $(date +%s) )); [ "$left" -gt 60 ] && left=60
  watch_cycle "$left" "${KN[@]}" || true
  drain_ack
done
log '=== results'
for t in dated undated malformed; do
  log "status[$t]:"; while IFS= read -r l; do log "  $l"; done < "$ST/$t.status"
  log "  overdue decision lines: $(grep -cF "blocked [key=paused-overdue-$t]" "$ST/$t.status" || true)"
  log "  open decisions: $(open_decisions "$t" | tr '\n' ' ')"
  log "  overdue stale wakes: $(grep -cE "drain: [0-9]+[[:space:]]+[0-9]+[[:space:]]+stale[[:space:]]+lab:fm-$t[[:space:]]+stale: lab:fm-$t \(paused [0-9]+s, wait overdue" "$EVLOG" || true)"
done
panes=$(lab_env tmux list-panes -a -F '#{window_name}:#{pane_dead}' | tr '\n' ' ')
log "worker panes after: $panes"
[ "$(grep -cF 'blocked [key=paused-overdue-dated]' "$ST/dated.status" || true)" -eq 1 ] || exit 1
[ "$(grep -cF 'blocked [key=paused-overdue-undated]' "$ST/undated.status" || true)" -eq 1 ] || exit 1
[ "$(grep -cF 'blocked [key=paused-overdue-malformed]' "$ST/malformed.status" || true)" -eq 0 ] || exit 1
[ "$(grep -cE 'drain: [0-9]+[[:space:]]+[0-9]+[[:space:]]+stale[[:space:]]+lab:fm-dated[[:space:]]+stale: lab:fm-dated \(paused [0-9]+s, wait overdue' "$EVLOG" || true)" -eq 1 ] || exit 1
[ "$(grep -cE 'drain: [0-9]+[[:space:]]+[0-9]+[[:space:]]+stale[[:space:]]+lab:fm-undated[[:space:]]+stale: lab:fm-undated \(paused [0-9]+s, wait overdue' "$EVLOG" || true)" -eq 1 ] || exit 1
printf '%s\n' "$panes" | grep -Eq '(^|[[:space:]])fm-dated:0([[:space:]]|$)' || exit 1
printf '%s\n' "$panes" | grep -Eq '(^|[[:space:]])fm-undated:0([[:space:]]|$)' || exit 1
printf '%s\n' "$panes" | grep -Eq '(^|[[:space:]])fm-malformed:0([[:space:]]|$)' || exit 1
log 'PASS: dated and undated each opened one blocked decision and one stale wake; malformed dated stayed on bounded rechecks; all worker panes remained alive'
cp "$EVLOG" "$LIVE_DIR/out/overdue-watcher-evidence.log"
cp "$ST/.watch-triage.log" "$LIVE_DIR/out/overdue-watcher-triage.log" 2>/dev/null || true

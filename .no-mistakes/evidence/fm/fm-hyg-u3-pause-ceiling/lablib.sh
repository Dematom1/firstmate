# shellcheck shell=bash
# Shared lab plumbing for the live watcher evidence runs.
# Usage: . lablib.sh; lab_init <pr-clone-dir> <label>
# Sets: CODE (PR head clone), ROOT (mktemp lab root), LABH (marked lab FM_HOME),
#       TMUX_DIR (private socket dir), SOCK (unique -L name), SHIM (dir with tmux shim + stubs)
set -u
REAL_TMUX=$(command -v tmux)
LIVE_DIR=/Users/laszlohoranszky/.treehouse/agent-workspace-b8697d/3/agent-workspace/data/fm-hyg-u3-pause-ceiling/live

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$EVLOG"; }

lab_init() {  # <pr-clone> <label>
  CODE=$1
  ROOT=$(mktemp -d "$LIVE_DIR/lab-$2.XXXXXX")
  LABH="$ROOT/home"
  EVLOG="$ROOT/evidence.log"
  : > "$EVLOG"
  "$CODE/bin/fm-lab-home.sh" create "$LABH" >/dev/null || return 1
  TMUX_DIR=$("$CODE/bin/fm-lab-home.sh" tmux-dir "$LABH") || return 1
  SOCK="fmlv$$"
  SHIM="$ROOT/shim"
  mkdir -p "$SHIM"
  cat > "$SHIM/tmux" <<EOF
#!/bin/sh
exec env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TMUX_DIR" "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
  chmod +x "$SHIM/tmux"
  trap lab_cleanup EXIT
  log "lab root=$ROOT home=$LABH code=$CODE head=$(git -C "$CODE" rev-parse HEAD) tmux=-L $SOCK TMUX_TMPDIR=$TMUX_DIR"
}

# Clean environment: no Rex/Herdr/tmux/FM markers from the operator session.
lab_env_vars() {
  printf '%s\n' "HOME=$LABH" "USER=${USER:-$(id -un)}" "LOGNAME=${USER:-$(id -un)}" \
    "PATH=$SHIM:$PATH" SHELL=/bin/bash TERM=xterm-256color LANG=en_US.UTF-8 \
    "TMUX_TMPDIR=$TMUX_DIR" "TREEHOUSE_ROOT=$ROOT/treehouse" FM_BACKEND=tmux \
    FM_LIVE=0 DISABLE_AUTOUPDATER=1 "FM_HOME=$LABH"
}
lab_env() { local -a v=(); local l; while IFS= read -r l; do v+=("$l"); done < <(lab_env_vars); env -i "${v[@]}" "$@"; }
# For `&` jobs: exec replaces the background subshell, so $! is the real process.
lab_env_exec() { local -a v=(); local l; while IFS= read -r l; do v+=("$l"); done < <(lab_env_vars); exec env -i "${v[@]}" "$@"; }

lab_cleanup() {
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null
  lab_env "$SHIM/tmux" kill-server 2>/dev/null || true
  "$CODE/bin/fm-lab-home.sh" teardown "$LABH" >/dev/null 2>&1 || true
}

# Run one watcher cycle in the clean env with the given extra env; stdout lines
# are timestamped into $EVLOG; returns the watcher exit status.
# Background helper: watch_cycle <timeout-secs> [VAR=VAL...]
watch_cycle() {
  local limit=$1 rc out
  shift
  out="$ROOT/watch.$(date +%s).out"
  lab_env_exec "$@" "$CODE/bin/fm-watch.sh" > "$out" 2> "$out.err" &
  WATCH_PID=$!
  local i=0
  while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt "$limit" ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$WATCH_PID" 2>/dev/null; then
    log "watcher pid $WATCH_PID still blocking after ${limit}s (no wake); stopping it"
    kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; rc=124
  else
    wait "$WATCH_PID"; rc=$?
  fi
  WATCH_PID=
  while IFS= read -r l; do log "watcher stdout: $l"; done < "$out"
  [ -s "$out.err" ] && while IFS= read -r l; do log "watcher stderr: $l"; done < "$out.err"
  log "watcher exit=$rc after ~${i}s"
  return "$rc"
}

# Drain like the supervision protocol does, log it, then ack exactly what it printed.
drain_ack() {
  local err="$ROOT/drain.err" out="$ROOT/drain.out" seq gen
  lab_env "$CODE/bin/fm-wake-drain.sh" > "$out" 2> "$err"
  while IFS= read -r l; do log "drain: $l"; done < "$out"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    lab_env "$CODE/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
    log "drain: acked through $seq"
  else
    log "drain: nothing to ack ($(tr '\n' ' ' < "$err" | cut -c1-200))"
  fi
}

set_mtime_ago() {  # <file> <seconds-ago>
  local back=$(( $(date +%s) - $2 ))
  touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$1"
}

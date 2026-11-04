#!/usr/bin/env bash
# Opt-in credentialed live guard for supervision across a Claude session resume
# (the SessionStart "resume" registration of bin/fm-claude-stop-autoarm.sh,
# docs/watcher-continuity.md "Claude session resume").
#
# Proves against the real installed Claude Code, in an isolated lab copy of this
# checkout with the real supervision host and watcher (never a live fleet home),
# that a new process resuming the primary session monitors and handles wakes
# with nobody typing:
#   1. graceful: the primary exits while idle and a main-only event lands during
#      the downtime; after `claude --resume` the hook reclaims the dead owner's
#      lock and one host and watcher start, the resume's session-start nudge
#      reaches the model, and with no prompt submitted the rewake opens a turn
#      that drains the event;
#   2. hard kill: SIGKILL leaves the old hook and host running as orphans whose
#      claim still reads as open, the shape a crashed worker leaves; the resume
#      takes the next generation, exactly one watcher remains, and an event that
#      lands then reaches the resumed session, not the orphan.
# With FM_CLAUDE_RESUME_LIVE_CONTROL_REF=<git ref>, scenario 1 first runs with
# that ref's .claude/settings.json as a negative control and must show the
# resumed primary NOT woken, so the scenario is proven able to catch the gap.
# Evidence lines start with "# ".
#
#   FM_CLAUDE_RESUME_LIVE_E2E=1 tests/fm-claude-resume-supervision-live-e2e.test.sh
#
# FM_CLAUDE_RESUME_LIVE_MODEL (default haiku) picks the primary's model. Claude
# keeps its existing managed authentication; the lab path gets a workspace-trust
# entry and a project transcript directory in Claude's own store.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

fm_live_gate opt-in FM_CLAUDE_RESUME_LIVE_E2E claude tmux jq node perl git

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
MODEL=${FM_CLAUDE_RESUME_LIVE_MODEL:-haiku}
CONTROL_REF=${FM_CLAUDE_RESUME_LIVE_CONTROL_REF:-}
LAB=$(fm_test_tmproot fm-claude-resume-live)
LAB=$(cd -P "$LAB" && pwd -P)
SOCKET="fmcrl-$$"
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
TURN_POLLS=${FM_CLAUDE_RESUME_LIVE_POLLS:-1800}
CONTROL_QUIET_SECONDS=${FM_CLAUDE_RESUME_LIVE_CONTROL_SECONDS:-60}
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE TMUX TMUX_PANE PI_CODING_AGENT NO_MISTAKES_GATE
# Claude Code keeps no transcript for a session that inherits another session's
# markers, so the lab primary starts without the invoking session's.
while IFS= read -r name; do
  unset "$name"
done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | cut -d= -f1 | sort -u)

evidence() { printf '# %s %s\n' "$(date '+%H:%M:%S')" "$*"; }

[ -d /proc/self/fd ] || fail "this guard counts watchers through /proc, which this host lacks"

# Running watchers, from the script fd bash holds open, so a duplicate cycle is
# countable without reading any command line. A forked subshell inherits that
# fd, so only the topmost process of each counts.
lab_watchers() {
  local script="$1/fm/bin/fm-watch.sh" fd pid parent n=0
  for fd in /proc/[0-9]*/fd/255; do
    [ "$(readlink "$fd" 2>/dev/null)" = "$script" ] || continue
    pid=${fd#/proc/}
    parent=$(ps -o ppid= -p "${pid%%/*}" 2>/dev/null | tr -d ' ')
    [ "$(readlink "/proc/$parent/fd/255" 2>/dev/null)" = "$script" ] || n=$((n + 1))
  done
  printf '%s\n' "$n"
}
# Every process working inside this lab, for cleanup.
lab_pids() {
  local cwd pid
  for cwd in /proc/[0-9]*/cwd; do
    case "$(readlink "$cwd" 2>/dev/null)" in
      "$1"|"$1"/*) pid=${cwd#/proc/}; printf '%s\n' "${pid%%/*}" ;;
    esac
  done
}

stop_lab() {  # <lab>
  local lab=$1 pid
  tmux -L "$SOCKET-$(basename "$lab")" kill-server >/dev/null 2>&1 || true
  sleep 1
  for pid in $(lab_pids "$lab"); do kill -TERM "$pid" 2>/dev/null || true; done
  rm -rf "${PROJECTS:?}/$(printf '%s' "$lab/fm" | sed 's/[^A-Za-z0-9]/-/g')"
}
cleanup() {
  local lab
  for lab in "$LAB"/*/; do
    [ -d "$lab/fm" ] && stop_lab "${lab%/}"
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

make_lab() {  # <name> [settings-ref]
  local lab="$LAB/$1" ref=${2:-} fm
  fm="$lab/fm"
  mkdir -p "$fm" "$lab/bin"
  git -C "$ROOT" ls-files -z -co --exclude-standard \
    | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$fm" && tar -xf -)
  if [ -n "$ref" ]; then
    git -C "$ROOT" show "$ref:.claude/settings.json" > "$fm/.claude/settings.json" \
      || fail "control: could not read .claude/settings.json at $ref"
  fi
  git -C "$fm" init -q -b main
  git -C "$fm" add -A >/dev/null
  git -C "$fm" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
  mkdir -p "$fm/state" "$fm/config" "$fm/data"
  : > "$fm/config/supervision-host"
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$fm/state/demo.meta"
  : > "$fm/state/demo.status"
  # An unreachable tmux: the watcher reads no endpoint, so the only wakes are
  # the events this guard appends.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$lab/bin/tmux"
  chmod +x "$lab/bin/tmux"
  cat > "$lab/env" <<ENV
export FM_HOME='$fm'
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0
export PATH='$lab/bin':"\$PATH"
ENV
  printf '%s\n' "$lab"
}

transcript() {  # <lab>
  find "$PROJECTS/$(printf '%s' "$1/fm" | sed 's/[^A-Za-z0-9]/-/g')" -maxdepth 1 -name '*.jsonl' -print 2>/dev/null | head -n 1
}
rewakes_since() {  # <lab> <epoch>
  local t
  t=$(transcript "$1")
  [ -n "$t" ] || return 0
  jq -r --argjson since "$2" '
    select(.type == "queue-operation" and .operation == "enqueue")
    | select((.content // "" | tostring) | contains("firstmate watcher wake"))
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since) | $at' "$t" 2>/dev/null
}
commands_since() {  # <lab> <epoch>
  local t
  t=$(transcript "$1")
  [ -n "$t" ] || return 0
  jq -r --argjson since "$2" '
    select(.type == "assistant")
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since)
    | .message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command' "$t" 2>/dev/null
}
# A turn ran the drain, the proof the wake reached the session. What the model
# then does with it follows the digest it just read, so it is evidence, not a gate.
drained_since() { commands_since "$1" "$2" | grep -q 'fm-wake-drain.sh'; }
# The resume's session-start instruction reached the transcript at or after
# <epoch>. Claude persists hook output with the first turn, so ask after a turn.
nudged_since() {  # <lab> <epoch>
  jq -e --argjson since "$2" '
    select(.timestamp? and ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since))
    | select(tostring | contains("FIRSTMATE_OP: v1 session-start"))' "$(transcript "$1")" >/dev/null 2>&1
}
turn_idle() {  # <lab> <after-epoch>
  local t
  t=$(transcript "$1")
  [ -n "$t" ] || return 1
  jq -e --argjson since "$2" '
    select(.type == "system" and .subtype == "turn_duration")
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)' "$t" >/dev/null 2>&1
}
# Prompts a person typed: each is a user message with plain string content that
# is not a harness-queued notification.
typed_prompts() {
  jq -r 'select(.type == "user" and (.message.content | type == "string"))
    | select(.message.content | contains("<task-notification>") | not) | .timestamp' "$(transcript "$1")" 2>/dev/null | wc -l | tr -d ' '
}
host_log_since() {  # <lab> <epoch> <regex>
  awk -F '\t' -v t="$2" '$1 >= t' "$1/fm/state/.supervision-host.log" 2>/dev/null | grep -E -- "$3"
}
host_live() {
  local pid
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$1/fm/state/.supervision-host" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
watcher_pid() { cat "$1/fm/state/.watch.lock/pid" 2>/dev/null; }
watcher_live() { local pid; pid=$(watcher_pid "$1") && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
one_watcher() { [ "$(lab_watchers "$1")" = 1 ]; }
lock_is() { [ "$(cat "$1/fm/state/.lock" 2>/dev/null)" = "$2" ]; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
ledger() { head -n 1 "$1/fm/state/.claude-autoarm-epoch" 2>/dev/null; }
diagnose() {  # <lab>
  printf -- '--- host log\n%s\n--- cycle exits\n%s\n--- queue\n%s\n--- ledger: %s\n--- marker: %s\n--- watchers: %s\n--- screen\n%s\n' \
    "$(tail -n 8 "$1/fm/state/.supervision-host.log" 2>/dev/null)" \
    "$(tail -n 4 "$1/fm/state/.watch-cycle-exits.log" 2>/dev/null | cut -f1-8)" \
    "$(cat "$1/fm/state/.wake-queue" 2>/dev/null)" "$(ledger "$1")" \
    "$(cat "$1/fm/state/.watcher-down" 2>/dev/null)" "$(lab_watchers "$1")" \
    "$(tmux -L "$SOCKET-$(basename "$1")" capture-pane -p -t primary 2>/dev/null | tail -n 25)"
}

# Answer one first-run dialog in the lab by moving its cursor to <option>.
choose() {  # <socket> <screen> <option>
  local cursor target moves key
  cursor=$(printf '%s\n' "$2" | grep -n '❯' | head -n 1 | cut -d: -f1)
  target=$(printf '%s\n' "$2" | grep -nF -- "$3" | head -n 1 | cut -d: -f1)
  [ -n "$cursor" ] && [ -n "$target" ] || return 0
  moves=$((target - cursor))
  key=Down
  [ "$moves" -ge 0 ] || { key=Up; moves=$((0 - moves)); }
  while [ "$moves" -gt 0 ]; do
    tmux -L "$1" send-keys -t primary "$key"
    sleep 0.3
    moves=$((moves - 1))
  done
  tmux -L "$1" send-keys -t primary Enter
  sleep 3
}

claude_ready_state() {  # <socket> <target>
  local socket=$1 target=$2 busy composer
  tmux() { command tmux -L "$socket" "$@"; }
  busy=$(fm_pane_busy_state "$target" claude)
  composer=$(fm_tmux_composer_state "$target")
  printf 'busy=%s composer=%s' "$busy" "$composer"
  [ "$busy" = idle ] && [ "$composer" = empty ]
}

# Answer first-run dialogs only; a resumed session types nothing after this.
pass_dialogs() {  # <lab>
  local sock screen i=0 readiness=unknown
  sock="$SOCKET-$(basename "$1")"
  while [ "$i" -lt 90 ]; do
    screen=$(tmux -L "$sock" capture-pane -p -t primary 2>/dev/null)
    case "$screen" in
      *'Yes, I trust this folder'*) choose "$sock" "$screen" 'Yes, I trust this folder' ;;
      *'Yes, I accept'*) choose "$sock" "$screen" 'Yes, I accept' ;;
      *'external CLAUDE.md'*|*'external imports'*) choose "$sock" "$screen" 'Yes, allow external imports' ;;
      *) readiness=$(claude_ready_state "$sock" primary) && return 0 ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  fail "$(basename "$1"): Claude never reached an idle empty composer ($readiness)"$'\n'"$(diagnose "$1")"
}

launch() {  # <lab> [claude args...]
  local lab=$1 sock
  shift
  sock="$SOCKET-$(basename "$lab")"
  tmux -L "$sock" kill-session -t primary >/dev/null 2>&1 || true
  # The pane outlives Claude, so a killed Claude's process tree is not hung up.
  tmux -L "$sock" new-session -d -s primary -x 220 -y 50 -c "$lab/fm" \
    "sh -c '. \"$lab/env\"; claude --model $MODEL --effort low --permission-mode auto $*; exec sleep 3600'" \
    || fail "$(basename "$lab"): the tmux session did not start"
}

stable_cycle() {  # <lab>: host, watcher, and idle session unbroken for ten seconds
  local sock n=0 i=0
  sock="$SOCKET-$(basename "$1")"
  while [ "$i" -lt "$TURN_POLLS" ]; do
    # The subshell keeps the readiness helper's tmux wrapper out of this shell.
    if host_live "$1" && watcher_live "$1" && (claude_ready_state "$sock" primary) >/dev/null; then
      n=$((n + 1))
    else
      n=0
    fi
    [ "$n" -ge 10 ] && return 0
    sleep 1
    i=$((i + 10))
  done
  return 1
}

# Start an idle primary with the host parked on a live watcher.
start_primary() {  # <lab>
  local lab=$1 sock started prompt
  sock="$SOCKET-$(basename "$lab")"
  prompt='This is an isolated Firstmate test lab, not a real fleet. Reply with exactly READY now and use no tools. Later, whenever a "Stop hook feedback" message wakes you, do exactly this and nothing else: if the session was told to run bin/fm-session-start.sh and has not since, run that once with the Bash tool first; then run `bin/fm-wake-drain.sh` once with the Bash tool, then run the exact `bin/fm-wake-drain.sh --ack-through ...` command that its WAKE_ACK_REQUIRED line prints, then reply with exactly ACKED. Never run any other command, never run bin/fm-watch-arm.sh, and never use any other tool.'
  started=$(date +%s)
  launch "$lab"
  pass_dialogs "$lab"
  sleep 2
  tmux -L "$sock" send-keys -t primary -l "$prompt"
  sleep 1
  tmux -L "$sock" send-keys -t primary Enter
  wait_until "$TURN_POLLS" host_live "$lab" \
    || fail "$(basename "$lab"): the setup turn's Stop hook never started the host"$'\n'"$(diagnose "$lab")"
  wait_until 300 watcher_live "$lab" || fail "$(basename "$lab"): the host never started a watcher"$'\n'"$(diagnose "$lab")"
  wait_until "$TURN_POLLS" turn_idle "$lab" "$started" || fail "$(basename "$lab"): the setup turn never ended"$'\n'"$(diagnose "$lab")"
  # A fresh status file closes the first cycle at once and its wake opens a turn,
  # so each scenario starts only once the cycle has stayed up on an idle session.
  stable_cycle "$lab" || fail "$(basename "$lab"): the first cycle never settled"$'\n'"$(diagnose "$lab")"
  evidence "$(basename "$lab"): primary idle (claude pid $(cat "$lab/fm/state/.lock"), $CLAUDE_VERSION, model $MODEL); host pid $(awk -F '\t' '$1 == "host" { print $2; exit }' "$lab/fm/state/.supervision-host") on watcher $(watcher_pid "$lab")"
}

session_id() { basename "$(transcript "$1")" .jsonl; }
fire() {  # <lab> <key> <text>
  local at
  at=$(date +%s)
  printf 'needs-decision [at=%s] [key=%s]: %s\n' "$at" "$2" "$3" >> "$1/fm/state/demo.status"
  printf '%s\n' "$at"
}
# The resume is a real new process, so the lock names it only once the hook ran.
lock_names_new_owner() { local pid; pid=$(cat "$1/fm/state/.lock" 2>/dev/null); [ -n "$pid" ] && [ "$pid" != "$2" ] && kill -0 "$pid" 2>/dev/null; }

run_graceful() {
  local lab old_pid sid e1 resumed typed
  lab=$(make_lab graceful)
  start_primary "$lab"
  old_pid=$(cat "$lab/fm/state/.lock")
  sid=$(session_id "$lab")
  typed=$(typed_prompts "$lab")
  kill -TERM "$old_pid"
  wait_until 300 pid_gone "$old_pid" || fail "graceful: the primary did not exit on TERM"
  wait_until 300 test ! -e "$lab/fm/state/.watch.lock/pid" \
    || evidence "graceful: a watcher lock is still present after the exit: $(watcher_pid "$lab")"
  e1=$(fire "$lab" res-e1 'pick export format A or B')
  evidence "graceful: primary $old_pid exited; event appended at $e1 during the downtime"
  sleep 3
  resumed=$(date +%s)
  launch "$lab" --resume "$sid"
  pass_dialogs "$lab"
  wait_until "$TURN_POLLS" lock_names_new_owner "$lab" "$old_pid" \
    || fail "graceful: the resume did not reclaim the dead owner's lock"$'\n'"$(diagnose "$lab")"
  evidence "graceful: resumed with no prompt; lock now names $(cat "$lab/fm/state/.lock")"
  wait_until "$TURN_POLLS" drained_since "$lab" "$resumed" \
    || fail "graceful: the idle resumed primary was not woken to handle the event"$'\n'"$(diagnose "$lab")"
  [ -n "$(rewakes_since "$lab" "$resumed")" ] || fail "graceful: no rewake reached the transcript"
  [ "$(typed_prompts "$lab")" = "$typed" ] || fail "graceful: a prompt was typed after the resume"
  nudged_since "$lab" "$resumed" \
    || fail "graceful: the resume's session-start nudge never reached the model"$'\n'"$(diagnose "$lab")"
  evidence "graceful: rewake delivered at $(rewakes_since "$lab" "$resumed" | head -n 1); host log: $(host_log_since "$lab" "$resumed" '.' | cut -f1-4 | tr '\n' ';' | cut -c1-300)"
  evidence "graceful: resumed turn ran: $(commands_since "$lab" "$resumed" | tr '\n' ';' | cut -c1-300)"
  wait_until "$TURN_POLLS" turn_idle "$lab" "$resumed" || fail "graceful: the woken turn never ended"$'\n'"$(diagnose "$lab")"
  wait_until 300 watcher_live "$lab" || fail "graceful: no watcher after the woken turn"$'\n'"$(diagnose "$lab")"
  wait_until 300 one_watcher "$lab" || fail "graceful: expected one watcher, found $(lab_watchers "$lab")"$'\n'"$(diagnose "$lab")"
  evidence "graceful: exactly one watcher ($(watcher_pid "$lab")) after the woken turn"
  stop_lab "$lab"
  pass "resume live ($CLAUDE_VERSION): a graceful restart re-arms and handles the downtime's event with no prompt typed"
}

run_hard_kill() {
  local lab old_pid old_host old_owner sid resumed e1 typed
  lab=$(make_lab hardkill)
  start_primary "$lab"
  old_pid=$(cat "$lab/fm/state/.lock")
  old_host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$lab/fm/state/.supervision-host")
  old_owner=$(sed -n 's/.* owner_pid=\([0-9]*\) .*/\1/p' "$lab/fm/state/.claude-autoarm-epoch" | head -n 1)
  sid=$(session_id "$lab")
  typed=$(typed_prompts "$lab")
  kill -KILL "$old_pid"
  wait_until 300 pid_gone "$old_pid" || fail "hard kill: the primary survived SIGKILL"
  sleep 3
  { kill -0 "$old_host" && kill -0 "$old_owner"; } 2>/dev/null \
    || fail "hard kill: the old hook $old_owner or host $old_host died with Claude, so this run exercises no orphan"$'\n'"$(diagnose "$lab")"
  evidence "hard kill: primary $old_pid killed; orphan hook $old_owner and host $old_host alive; ledger: $(ledger "$lab")"
  resumed=$(date +%s)
  tmux -L "$SOCKET-$(basename "$lab")" rename-session -t primary orphan
  launch "$lab" --resume "$sid"
  pass_dialogs "$lab"
  wait_until "$TURN_POLLS" lock_names_new_owner "$lab" "$old_pid" \
    || fail "hard kill: the resume did not reclaim the dead owner's lock"$'\n'"$(diagnose "$lab")"
  wait_until "$TURN_POLLS" host_log_since "$lab" "$resumed" $'\tstart\tgen=' >/dev/null \
    || fail "hard kill: the resume started no host"$'\n'"$(diagnose "$lab")"
  wait_until 300 watcher_live "$lab" || fail "hard kill: no watcher after the resume"$'\n'"$(diagnose "$lab")"
  wait_until 300 one_watcher "$lab" || fail "hard kill: expected one watcher, found $(lab_watchers "$lab")"$'\n'"$(diagnose "$lab")"
  evidence "hard kill: lock names $(cat "$lab/fm/state/.lock"); one watcher ($(watcher_pid "$lab")); old hook alive=$(kill -0 "$old_owner" 2>/dev/null && echo yes || echo no); old host alive=$(kill -0 "$old_host" 2>/dev/null && echo yes || echo no); ledger: $(ledger "$lab")"
  # Let any recovery wake the resume itself raised settle, so the event below is
  # judged on its own.
  stable_cycle "$lab" || fail "hard kill: the resumed cycle never settled"$'\n'"$(diagnose "$lab")"
  e1=$(fire "$lab" res-e2 'pick region east or west')
  evidence "hard kill: event appended at $e1"
  wait_until "$TURN_POLLS" drained_since "$lab" "$e1" \
    || fail "hard kill: the event never reached the resumed session"$'\n'"$(diagnose "$lab")"
  [ "$(typed_prompts "$lab")" = "$typed" ] || fail "hard kill: a prompt was typed after the resume"
  nudged_since "$lab" "$resumed" \
    || fail "hard kill: the resume's session-start nudge never reached the model"$'\n'"$(diagnose "$lab")"
  evidence "hard kill: resumed session ran: $(commands_since "$lab" "$resumed" | tr '\n' ';' | cut -c1-300)"
  wait_until "$TURN_POLLS" turn_idle "$lab" "$e1" || fail "hard kill: the woken turn never ended"$'\n'"$(diagnose "$lab")"
  wait_until 300 one_watcher "$lab" || fail "hard kill: expected one watcher after the turn, found $(lab_watchers "$lab")"$'\n'"$(diagnose "$lab")"
  stop_lab "$lab"
  pass "resume live ($CLAUDE_VERSION): a hard kill's orphaned cycle gives way to one watcher that delivers to the resumed session"
}

# The negative control: the same downtime event with the control ref's
# registration must leave the resumed primary asleep and unmonitored.
run_control() {
  local lab old_pid sid e1 resumed
  lab=$(make_lab control "$CONTROL_REF")
  start_primary "$lab"
  old_pid=$(cat "$lab/fm/state/.lock")
  sid=$(session_id "$lab")
  kill -TERM "$old_pid"
  wait_until 300 pid_gone "$old_pid" || fail "control: the primary did not exit on TERM"
  e1=$(fire "$lab" res-e1 'pick export format A or B')
  sleep 3
  resumed=$(date +%s)
  evidence "control ($CONTROL_REF): primary $old_pid exited; event appended at $e1"
  launch "$lab" --resume "$sid"
  pass_dialogs "$lab"
  sleep "$CONTROL_QUIET_SECONDS"
  if [ -n "$(rewakes_since "$lab" "$resumed")" ] || drained_since "$lab" "$resumed"; then
    fail "control: the resumed primary WAS woken on $CONTROL_REF, so this scenario cannot catch the gap"$'\n'"$(diagnose "$lab")"
  fi
  lock_is "$lab" "$old_pid" || fail "control: the lock moved with no hook to move it: $(cat "$lab/fm/state/.lock")"
  evidence "control: after ${CONTROL_QUIET_SECONDS}s no rewake, no primary command, lock still names dead $old_pid, watchers: $(lab_watchers "$lab")"
  stop_lab "$lab"
  pass "resume live control ($CLAUDE_VERSION): on $CONTROL_REF a resumed primary sits unmonitored, so the scenario catches the gap"
}

if [ -n "$CONTROL_REF" ]; then
  run_control
else
  printf 'skip: control: set FM_CLAUDE_RESUME_LIVE_CONTROL_REF to a pre-fix ref to run the negative control\n'
fi
run_graceful
run_hard_kill

#!/usr/bin/env bash
# bin/backends/herdr-core.sh - the herdr-core session-provider adapter
# (EXPERIMENTAL).
#
# herdr-core is a separate product from herdr (bin/backends/herdr.sh): its CLI
# is `hc`, it has no workspaces, tabs, or panes, and every program runs in a
# flat, persistent "terminal" addressed as t1, t2, ... inside one per-user core.
# It is a session provider ONLY: treehouse stays the worktree provider.
# docs/herdr-core-backend.md owns setup, detection, limits, and the live
# verification record (hc 0.1.13, Linux).
#
# Container shape: ONE terminal per task, running the user's login shell in the
# project directory, exactly like a tmux window. There is no per-home
# container; every terminal carries two labels instead:
#   fm_home=<fm_backend_hometag>   which firstmate installation/home owns it
#   fm_task=<task id>              which task it belongs to
# Labels are the only ownership proof this adapter accepts. A terminal whose
# labels do not name this home (and, when the caller knows it, this task) is
# never read, typed into, killed, or removed through this adapter - it reads as
# `missing`, because whatever owned that address for us is gone.
#
# Target string shape: "<hc-session>:<address>", for example "default:t7".
# Addresses are per core, and `hc` picks its core from HC_SESSION (default
# "default"), so the session is recorded and pinned on every call: a caller
# whose own ambient HC_SESSION differs still reaches the recorded core.
#
# Verified hc 0.1.13 facts that shaped this adapter (docs/herdr-core-backend.md
# has the evidence):
#   1. `hc send` pastes AND presses Enter in one call; there is no unsubmitted
#      paste, and `hc keys` accepts only named keys (no `_`), so there is no
#      literal-text primitive. Submits are one `hc send` plus Enter-only
#      retries; fm-spawn.sh sends its launch line the same way.
#   2. `hc run` defaults its parent to the calling terminal: the child ENDS
#      when the parent's program ends and notes are typed into the parent.
#      Firstmate itself runs in an hc terminal, so every task terminal is
#      created with --no-parent and --no-notify.
#   3. `hc get --json` reports the foreground process (name, argv, pid, cwd);
#      the cwd follows a subshell's own `cd`, so no shell probe is needed.
#   4. `hc read` trims trailing blank screen rows; `--lines 0` is the screen
#      only, so it doubles as the viewport-bounded capture.
#   5. Exit codes: 3 not_found, 9 blocked (send refused at a permission
#      prompt), 11 finished.
#
# Requires: hc (herdr-core 0.1.13 or newer), jq. Bootstrap detects these
# through fm_backend_required_tools only when herdr-core is the resolved
# backend; this adapter also gates them again before spawning.

FM_BACKEND_HERDR_CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_CORE_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_HERDR_CORE_ROOT/bin/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_HERDR_CORE_ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_HERDR_CORE_ROOT/bin/fm-agent-process-lib.sh"

# Verified minimum: the version the live pass ran against.
FM_BACKEND_HERDR_CORE_MIN_VERSION=0.1.13

fm_backend_herdr_core_tool_check() {
  command -v hc >/dev/null 2>&1 || { echo "error: backend=herdr-core selected but the 'hc' CLI is not installed (herdr-core $FM_BACKEND_HERDR_CORE_MIN_VERSION or newer; see docs/herdr-core-backend.md)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=herdr-core selected but 'jq' is not installed (required to parse hc's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_herdr_core_version_ge: dotted-numeric <a> >= <b>.
fm_backend_herdr_core_version_ge() {  # <a> <b>
  local a=$1 b=$2 x y
  while [ -n "$a$b" ]; do
    x=${a%%.*}; y=${b%%.*}
    x=${x:-0}; y=${y:-0}
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
    case "$a" in *.*) a=${a#*.} ;; *) a= ;; esac
    case "$b" in *.*) b=${b#*.} ;; *) b= ;; esac
  done
  return 0
}

# fm_backend_herdr_core_version_check: refuse a missing or older hc client.
# `hc --version` prints "hc <version>" and needs no running core.
fm_backend_herdr_core_version_check() {
  local raw ver
  fm_backend_herdr_core_tool_check || return 1
  raw=$(hc --version 2>/dev/null) || { echo "error: 'hc --version' failed; is herdr-core installed correctly?" >&2; return 1; }
  ver=${raw#hc }
  case "$ver" in
    ''|*[!0-9.]*|.*|*.)
      echo "error: could not parse an hc version from '$raw'; refusing to use an unverified herdr-core build" >&2
      return 1
      ;;
  esac
  if ! fm_backend_herdr_core_version_ge "$ver" "$FM_BACKEND_HERDR_CORE_MIN_VERSION"; then
    echo "error: herdr-core $ver is older than the verified minimum $FM_BACKEND_HERDR_CORE_MIN_VERSION; run 'hc update' before using backend=herdr-core" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_core_session: the hc session a NEW task lands in - the one
# this firstmate process itself addresses.
fm_backend_herdr_core_session() {
  printf '%s' "${HC_SESSION:-default}"
}

# fm_backend_herdr_core_cli: `hc <args...>` pinned to <session>'s core.
fm_backend_herdr_core_cli() {  # <session> <hc-args...>
  local session=$1
  shift
  HC_SESSION=$session hc "$@"
}

fm_backend_herdr_core_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_HERDR_CORE_SESSION=${target%%:*}
  FM_BACKEND_HERDR_CORE_ADDRESS=${target#*:}
  [ -n "$FM_BACKEND_HERDR_CORE_SESSION" ] && [ -n "$FM_BACKEND_HERDR_CORE_ADDRESS" ] \
    && [ "$FM_BACKEND_HERDR_CORE_ADDRESS" != "$target" ] || return 1
  case "$FM_BACKEND_HERDR_CORE_ADDRESS" in
    *:*|*/*) return 1 ;;
  esac
}

# fm_backend_herdr_core_create_task: start the task's shell terminal in <cwd>,
# labelled for this home and task. Echoes "<session> <address>".
fm_backend_herdr_core_create_task() {  # <fm-task-label> <cwd> [session]
  local label=$1 cwd=$2 session=${3:-} id home out addr
  [ -n "$session" ] || session=$(fm_backend_herdr_core_session)
  id=${label#fm-}
  home=$(fm_backend_hometag)
  if [ -n "$(fm_backend_herdr_core_cli "$session" ls --json --label "fm_home=$home" --label "fm_task=$id" 2>/dev/null \
    | jq -r '.terminals[]?.address' 2>/dev/null)" ]; then
    echo "error: a herdr-core terminal for task $id already exists in session $session" >&2
    return 1
  fi
  out=$(fm_backend_herdr_core_cli "$session" run --bg --json --no-parent --no-notify \
    --cwd "$cwd" --label "fm_home=$home" --label "fm_task=$id" 2>&1) || {
    echo "error: hc run failed for $label: $out" >&2
    return 1
  }
  addr=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)
  case "$addr" in
    ''|*:*|*/*)
      echo "error: hc run did not return a terminal address for $label: $out" >&2
      return 1
      ;;
  esac
  printf '%s %s' "$session" "$addr"
}

# fm_backend_herdr_core_get: read the target's facts into
# FM_BACKEND_HERDR_CORE_JSON after proving ownership. Returns 0 owned, 3 when
# the address is gone or now belongs to something else, 1 when unreadable.
fm_backend_herdr_core_get() {  # <target> [expected-label]
  local expected_label=${2:-} out rc=0 want_task home
  FM_BACKEND_HERDR_CORE_JSON=
  fm_backend_herdr_core_parse_target "$1" || return 1
  out=$(fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" get "$FM_BACKEND_HERDR_CORE_ADDRESS" --json 2>/dev/null) || rc=$?
  [ "$rc" -ne 3 ] || return 3
  [ "$rc" -eq 0 ] || return 1
  home=$(fm_backend_hometag)
  want_task=
  [ -z "$expected_label" ] || want_task=${expected_label#fm-}
  printf '%s' "$out" | jq -e --arg home "$home" --arg task "$want_task" '
    (.labels.fm_home // "") == $home
    and ((.labels.fm_task // "") | length > 0)
    and ($task == "" or .labels.fm_task == $task)' >/dev/null 2>&1 || {
    printf '%s' "$out" | jq -e '.address' >/dev/null 2>&1 || return 1
    return 3
  }
  FM_BACKEND_HERDR_CORE_JSON=$out
  return 0
}

# fm_backend_herdr_core_target_ready: owned and still running.
fm_backend_herdr_core_target_ready() {  # <target> [expected-label]
  fm_backend_herdr_core_get "$1" "${2:-}" || return 1
  [ "$(printf '%s' "$FM_BACKEND_HERDR_CORE_JSON" | jq -r '.state // empty' 2>/dev/null)" = live ]
}

# fm_backend_herdr_core_current_path: the foreground process's live cwd
# (finding #3). A shell that has not run anything yet reports no foreground,
# and its cwd is still the creation cwd.
fm_backend_herdr_core_current_path() {  # <target> [expected-label]
  fm_backend_herdr_core_target_ready "$1" "${2:-}" || return 0
  printf '%s' "$FM_BACKEND_HERDR_CORE_JSON" | jq -r '.foreground.cwd // .cwd // empty' 2>/dev/null
}

# fm_backend_herdr_core_send_text_line: paste <text> and press Enter (finding
# #1: one hc call does both). Refuses a terminal blocked at a prompt.
fm_backend_herdr_core_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_herdr_core_target_ready "$1" "${3:-}" || return 1
  fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" send "$FM_BACKEND_HERDR_CORE_ADDRESS" "$2" --json >/dev/null 2>&1
}

fm_backend_herdr_core_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'esc' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl+c' ;;
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl+u' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_herdr_core_send_key() {  # <target> <key> [expected-label]
  local key
  fm_backend_herdr_core_target_ready "$1" "${3:-}" || return 1
  key=$(fm_backend_herdr_core_normalize_key "$2")
  fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" keys "$FM_BACKEND_HERDR_CORE_ADDRESS" "$key" --json >/dev/null 2>&1
}

# fm_backend_herdr_core_capture: bounded plain-text read, history included.
fm_backend_herdr_core_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-200} out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fm_backend_herdr_core_get "$1" "${3:-}" || return 1
  out=$(fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" read "$FM_BACKEND_HERDR_CORE_ADDRESS" --lines "$lines" 2>/dev/null) || return 1
  printf '%s\n' "$out" | tail -n "$lines"
}

# fm_backend_herdr_core_visible_capture: the screen only, never history
# (finding #4: `hc read` without --lines reads zero history lines).
fm_backend_herdr_core_visible_capture() {  # <target> [expected-label]
  fm_backend_herdr_core_get "$1" "${2:-}" || return 1
  fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" read "$FM_BACKEND_HERDR_CORE_ADDRESS" --lines 0
}

# Composer reads are plain text with no cursor or identity facts, like cmux;
# bin/fm-composer-lib.sh owns every shape.
fm_backend_herdr_core_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

fm_backend_herdr_core_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_herdr_core_capture "$1" "$FM_COMPOSER_CAPTURE_LINES" "${2:-}") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_herdr_core_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_herdr_core_send_text_submit: one `hc send` (paste plus Enter),
# then Enter-only retries while the composer still provably holds the text.
# The shared fm_composer_submit_retry_core is not used because it presses
# Enter first, which here would land on an already-submitted turn. Echoes
# empty|pending|pending-unproven|unknown|send-failed.
fm_backend_herdr_core_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} i=0 state
  fm_backend_herdr_core_send_text_line "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    state=$(fm_backend_herdr_core_composer_state "$target" "$expected_label")
    if fm_composer_blocking_dialog_noted >/dev/null; then
      printf 'unknown'
      return 0
    fi
    case "$state" in
      pending|pending-unproven) ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    [ "$i" -lt "$retries" ] || break
    i=$((i + 1))
    fm_backend_herdr_core_send_key "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
  done
  fm_composer_queued_enter_verdict "$state" "$(fm_backend_herdr_core_busy_state "$target")"
}

# fm_backend_herdr_core_foreground_class: agent|shell|other for the owned
# terminal in FM_BACKEND_HERDR_CORE_JSON. The foreground process is what hc
# reports; before the shell first runs anything it reports none, and the
# terminal's own program (the shell) stands in.
fm_backend_herdr_core_foreground_class() {
  local fields name argv0 args pid
  fields=$(printf '%s' "$FM_BACKEND_HERDR_CORE_JSON" | jq -r '
    (.foreground // {name: null, argv: .argv, pid: .pid}) as $f
    | [($f.name // ($f.argv[0] // "" | split("/") | last)), ($f.argv[0] // ""),
       (($f.argv // []) | join(" ")), (($f.pid // "") | tostring)] | @tsv' 2>/dev/null) || { printf 'other'; return 0; }
  IFS=$'\t' read -r name argv0 args pid <<EOF
$fields
EOF
  fm_agent_process_classify "$name" "$argv0" "$args" "$pid"
}

# fm_backend_herdr_core_agent_state: see bin/fm-backend.sh's
# fm_backend_agent_state for the vocabulary. `missing` means the recorded
# session's own core answered that this home's terminal is not there; every
# read is pinned to that session, so the answer is about this endpoint only.
fm_backend_herdr_core_agent_state() {  # <target>
  local rc=0 state
  fm_backend_herdr_core_get "$1" || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  state=$(printf '%s' "$FM_BACKEND_HERDR_CORE_JSON" | jq -r '.state // empty' 2>/dev/null)
  case "$state" in
    finished) printf 'dead'; return 0 ;;
    live) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_backend_herdr_core_foreground_class)" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# fm_backend_herdr_core_busy_state: hc's native status (reported by the program
# itself, never guessed from the screen). `hc get` reports it as an object
# ({"app": "claude-code", "state": "working"}) while `hc ls` flattens it to the
# state string, so both shapes are read. `working` is trusted as busy only
# while a harness process is proven in the foreground.
fm_backend_herdr_core_busy_state() {  # <target>
  local status
  fm_backend_herdr_core_target_ready "$1" || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$FM_BACKEND_HERDR_CORE_JSON" \
    | jq -r '.status | if type == "object" then .state else . end // empty' 2>/dev/null)
  case "$status" in
    working)
      if [ "$(fm_backend_herdr_core_foreground_class)" = agent ]; then
        printf 'busy'
      else
        printf 'unknown'
      fi
      ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_core_kill: end and remove the task's terminal. A target that
# is gone, or whose address no longer carries this home's labels, is a silent
# success and is never touched. Nonzero only when an owned terminal provably
# survives or could not be read after the close.
fm_backend_herdr_core_kill() {  # <target> [unused] [expected-label]
  local target=$1 expected_label=${3:-} rc=0
  fm_backend_herdr_core_get "$target" "$expected_label" || rc=$?
  case "$rc" in
    0) ;;
    3) return 0 ;;
    *) echo "error: herdr-core terminal $target could not be read, so it was not closed" >&2; return 1 ;;
  esac
  fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" kill "$FM_BACKEND_HERDR_CORE_ADDRESS" --json >/dev/null 2>&1 || true
  fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" rm "$FM_BACKEND_HERDR_CORE_ADDRESS" --json >/dev/null 2>&1 || true
  rc=0
  fm_backend_herdr_core_cli "$FM_BACKEND_HERDR_CORE_SESSION" get "$FM_BACKEND_HERDR_CORE_ADDRESS" --json >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] && return 0
  echo "error: herdr-core terminal $target is still present after its close" >&2
  return 1
}

# fm_backend_herdr_core_list_live: recorded-inventory discovery, scoped by the
# fm_home label to this home only. One "<session>:<address>\tfm-<id>" line per
# live task terminal. Read-only; an unreachable core lists nothing.
fm_backend_herdr_core_list_live() {  # [session]
  local session=${1:-} home addr task
  [ -n "$session" ] || session=$(fm_backend_herdr_core_session)
  home=$(fm_backend_hometag)
  fm_backend_herdr_core_cli "$session" ls --json --label "fm_home=$home" 2>/dev/null \
    | jq -r '.terminals[]?.address // empty' 2>/dev/null \
    | while IFS= read -r addr; do
        task=$(fm_backend_herdr_core_cli "$session" get "$addr" --json 2>/dev/null \
          | jq -r --arg home "$home" 'select(.labels.fm_home == $home) | .labels.fm_task // empty' 2>/dev/null)
        [ -n "$task" ] && printf '%s:%s\tfm-%s\n' "$session" "$addr" "$task"
      done
  return 0
}

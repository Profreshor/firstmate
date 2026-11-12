#!/usr/bin/env bash
# tests/fm-backend-herdr-core.test.sh - fake-hc unit tests for the herdr-core
# session-provider adapter (bin/backends/herdr-core.sh), verified against the
# real hc 0.1.13 binary (docs/herdr-core-backend.md). The fake `hc` keeps a
# small JSON terminal table, answers with the real CLI's JSON shapes and exit
# codes (3 not_found), and logs every call with the HC_SESSION it was pinned to;
# jq is real, as it is a required tool for this backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr-core adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (runs the fake hc)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-core-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/hc" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FM_HC_STATE"]
with open(os.environ["FM_HC_LOG"], "a") as log:
    log.write("HC_SESSION=%s HC_TERMINAL_ID=%s HC_SCOPE=%s\x1f%s\n" %
              (os.environ.get("HC_SESSION", ""), os.environ.get("HC_TERMINAL_ID", ""),
               os.environ.get("HC_SCOPE", ""), "\x1f".join(sys.argv[1:])))
args = [a for a in sys.argv[1:] if a != "--json"]
if args[:1] == ["--version"]:
    print("hc " + os.environ.get("FM_HC_FAKE_VERSION", "0.1.13")); sys.exit(0)
with open(state_path) as f:
    st = json.load(f)
terms = st.setdefault("terminals", {})
def save():
    with open(state_path, "w") as f:
        json.dump(st, f)
def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default
def find(addr):
    t = terms.get(addr)
    if t is None:
        print(json.dumps({"error": {"kind": "not_found"}})); sys.exit(3)
    return t
cmd = args[0]
if os.environ.get("FM_HC_FAKE_FAIL") == cmd:
    sys.exit(1)
if cmd == "run":
    labels = dict(a.split("=", 1) for i, a in enumerate(args) if i and args[i - 1] == "--label")
    st["next"] = st.get("next", 1) + 1
    addr = "t%d" % st["next"]
    terms[addr] = {"address": addr, "argv": ["/usr/bin/zsh"], "cwd": opt("--cwd"), "pid": 4242,
                   "foreground": None, "labels": labels, "state": "live", "status": None, "screen": ""}
    save(); print(json.dumps({"address": addr, "state": "live"}))
elif cmd == "ls":
    want = [a.split("=", 1) for i, a in enumerate(args) if i and args[i - 1] == "--label"]
    out = [{"address": a} for a, t in terms.items()
           if t["state"] == "live" and all(t["labels"].get(k) == v for k, v in want)]
    print(json.dumps({"terminals": out}))
elif cmd == "get":
    print(json.dumps(find(args[1])))
elif cmd == "read":
    print(find(args[1])["screen"])
elif cmd in ("send", "keys"):
    t = find(args[1])
    t.setdefault("typed", []).append([cmd] + args[2:])
    if os.environ.get("FM_HC_FAKE_KIMI"):
        ready = "Welcome to Kimi Code!\ncontext: %s%%\n╭────────────────╮\n│ >              │\n╰────────────────╯"
        if cmd == "keys" and args[2:] == ["enter"]:
            t["trust_accepted"] = True
            t["screen"] = ready % "0"
        elif cmd == "send" and args[2].startswith("Read the brief at "):
            if not t.get("trust_accepted"):
                sys.exit("brief sent before folder trust was accepted")
            t["screen"] = ready % "1"
        elif cmd == "send":
            with open(os.environ["FM_HC_FAKE_KIMI"]) as f:
                t["screen"] = f.read()
    after = t.get("after_" + cmd)
    if after:
        t["screen"] = after.pop(0)
    save(); print(json.dumps({"turn": 0}))
elif cmd == "kill":
    t = find(args[1])
    if not t.get("survives"):
        t["state"] = "finished"
    save(); print(json.dumps(t))
elif cmd == "rm":
    t = find(args[1])
    if t["state"] == "finished":
        del terms[args[1]]
    save(); print(json.dumps({"removed": args[1]}))
PY
chmod +x "$FAKEBIN/hc"
export PATH="$FAKEBIN:$PATH"
export FM_HC_STATE="$TMP_ROOT/hc-state.json"
export FM_HC_LOG="$TMP_ROOT/hc.log"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
export FM_HOME="$HOME_DIR"
unset FM_ROOT_OVERRIDE HC_SESSION HC_TERMINAL_ID HERDR_ENV TMUX CMUX_WORKSPACE_ID FM_BACKEND
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr-core || fail "the herdr-core adapter did not source"
HOMETAG=$(fm_backend_hometag)

reset_hc() {
  printf '{"next": 1, "terminals": {}}' > "$FM_HC_STATE"
  : > "$FM_HC_LOG"
}

# set_terminal <address> <jq-update>: edit one fake terminal in place.
set_terminal() {
  local tmp="$FM_HC_STATE.tmp"
  jq --arg a "$1" ".terminals[\$a] |= ($2)" "$FM_HC_STATE" > "$tmp" && mv "$tmp" "$FM_HC_STATE"
}

add_foreign_terminal() {  # <address>
  local tmp="$FM_HC_STATE.tmp"
  jq --arg a "$1" '.terminals[$a] = {address: $a, argv: ["claude"], cwd: "/", pid: 1, labels: {},
    foreground: {name: "claude", argv: ["claude"], pid: 1, cwd: "/"}, state: "live", status: "working", screen: "captain"}' \
    "$FM_HC_STATE" > "$tmp" && mv "$tmp" "$FM_HC_STATE"
}

typed() {  # <address>
  jq -c --arg a "$1" '.terminals[$a].typed // []' "$FM_HC_STATE"
}

new_task() {  # <task-id> -> echoes target
  local ids
  ids=$(fm_backend_herdr_core_create_task "fm-$1" "$TMP_ROOT") || return 1
  printf '%s:%s' "${ids% *}" "${ids#* }"
}

test_version_gate() {
  FM_HC_FAKE_VERSION=0.1.13 fm_backend_herdr_core_version_check || fail "0.1.13 must pass the version gate"
  FM_HC_FAKE_VERSION=0.2.0 fm_backend_herdr_core_version_check || fail "0.2.0 must pass the version gate"
  FM_HC_FAKE_VERSION=0.1.12 fm_backend_herdr_core_version_check 2>/dev/null && fail "0.1.12 must be refused"
  FM_HC_FAKE_VERSION=garbage fm_backend_herdr_core_version_check 2>/dev/null && fail "an unparseable version must be refused"
  local out
  out=$(PATH=/usr/bin:/bin fm_backend_herdr_core_version_check 2>&1) && fail "a missing hc must be refused"
  assert_contains "$out" "'hc' CLI is not installed" "a missing hc must name the CLI"
  pass "version gate: accepts >= 0.1.13, refuses older, unparseable, and missing hc"
}

test_create_task_labels_and_detaches() {
  reset_hc
  local target log
  target=$(HC_SESSION=lab new_task t1) || fail "create_task failed"
  assert_equals "lab:t2" "$target" "create_task must return <session> <address> in the ambient session"
  log=$(grep $'\x1frun\x1f' "$FM_HC_LOG")
  assert_contains "$log" "HC_SESSION=lab" "run must be pinned to the session"
  assert_contains "$log" $'\x1f--no-parent\x1f--no-notify\x1f' "task terminals must not die with, or type notes into, the spawning terminal"
  assert_contains "$log" $'\x1f--cwd\x1f'"$TMP_ROOT"$'\x1f' "the terminal must start in the given cwd"
  assert_contains "$log" "fm_home=$HOMETAG" "the terminal must carry this home's label"
  assert_contains "$log" "fm_task=t1" "the terminal must carry its task label"
  HC_SESSION=lab new_task t1 2>/dev/null && fail "a second live terminal for the same task must be refused"
  pass "create_task: detached, labelled, session-pinned, and refuses a duplicate"
}

test_create_task_app_labels() {
  reset_hc
  local hash=${HOMETAG##*-} labels
  add_foreign_terminal t1
  set_terminal t1 '.labels = {"herdr.space": "spcaptain", "herdr.tab": "tbcaptain"}'
  HC_TERMINAL_ID=t1 new_task a >/dev/null || fail "create_task failed"
  HC_TERMINAL_ID=t1 new_task b >/dev/null || fail "create_task failed"
  labels=$(jq -c '[.terminals.t2.labels, .terminals.t3.labels] | map({s: .["herdr.space"], t: .["herdr.tab"]})' "$FM_HC_STATE")
  assert_equals "[{\"s\":\"sp${hash}crew\",\"t\":\"tb${hash}crew\"},{\"s\":\"sp${hash}crew\",\"t\":\"tb${hash}crew\"}]" "$labels" \
    "every worker of this home must share one crew space and tab"
  assert_equals '{"herdr.space":"spcaptain","herdr.tab":"tbcaptain"}' "$(jq -c '.terminals.t1.labels' "$FM_HC_STATE")" \
    "Firstmate's own terminal labels must be left alone"
  set_terminal t1 '.labels = {}'
  HC_TERMINAL_ID=t1 new_task c >/dev/null || fail "create_task failed"
  new_task d >/dev/null || fail "create_task failed"
  HC_TERMINAL_ID=t1 HC_SESSION=lab new_task e >/dev/null || fail "create_task failed"
  assert_equals "[]" "$(jq -c '[.terminals.t4, .terminals.t5, .terminals.t6 | .labels | keys[] | select(startswith("herdr."))]' "$FM_HC_STATE")" \
    "a Firstmate outside the app, or a task in another core, gets no app labels"
  pass "create_task: workers of a home in the app share one crew space and tab"
}

# crew_tabs <address>...: the crew-tab suffix each terminal was labelled with.
crew_tabs() {
  local hash=${HOMETAG##*-} address tabs=""
  for address in "$@"; do
    tabs="$tabs $(jq -r --arg a "$address" '.terminals[$a].labels["herdr.tab"]' "$FM_HC_STATE")"
  done
  printf '%s' "${tabs# }" | sed "s/tb${hash}//g"
}

test_create_task_crew_tab_cap() {
  reset_hc
  local hash=${HOMETAG##*-} i default_cap config="$HOME_DIR/config/herdr-presentation-spaces"
  mkdir -p "$HOME_DIR/config"
  printf 'crew:2\n' > "$config"
  add_foreign_terminal t1
  set_terminal t1 '.labels = {"herdr.space": "spcaptain", "herdr.tab": "tbcaptain"}'
  # Another home's terminal in the same tab id must not use up this home's slots.
  add_foreign_terminal t90
  set_terminal t90 ".labels = {fm_home: \"someone-else\", \"herdr.tab\": \"tb${hash}crew\"}"
  for i in 1 2 3 4 5; do
    HC_TERMINAL_ID=t1 new_task "cap$i" >/dev/null || fail "create_task failed"
  done
  assert_equals "crew crew crew2 crew2 crew3" "$(crew_tabs t2 t3 t4 t5 t6)" "crew:2 must fill each tab to the cap in order"
  assert_equals "sp${hash}crew" "$(jq -r '.terminals.t6.labels["herdr.space"]' "$FM_HC_STATE")" "every crew tab stays in the one crew space"
  set_terminal t2 '.state = "finished"'
  HC_TERMINAL_ID=t1 new_task refill >/dev/null || fail "create_task failed"
  assert_equals "crew" "$(crew_tabs t7)" "a freed slot in an earlier tab must be refilled first"

  reset_hc
  add_foreign_terminal t1
  set_terminal t1 '.labels = {"herdr.space": "spcaptain", "herdr.tab": "tbcaptain"}'
  FM_HC_FAKE_FAIL=ls HC_TERMINAL_ID=t1 new_task unreadable >/dev/null 2>&1 && fail "a failed crew-tab listing must refuse the spawn"
  assert_equals '["t1"]' "$(jq -c '.terminals | keys' "$FM_HC_STATE")" "a failed crew-tab listing must not create a worker"
  assert_no_grep $'\x1frun\x1f' "$FM_HC_LOG" "a failed crew-tab listing must not invoke hc run"

  reset_hc
  printf 'crew\n' > "$config"
  add_foreign_terminal t1
  set_terminal t1 '.labels = {"herdr.space": "spcaptain", "herdr.tab": "tbcaptain"}'
  default_cap=$(fm_backend_source herdr && printf '%s' "$FM_BACKEND_HERDR_CREW_PANE_CAP_DEFAULT")
  i=0
  while [ "$i" -le "$default_cap" ]; do
    i=$((i + 1))
    HC_TERMINAL_ID=t1 new_task "plain$i" >/dev/null || fail "create_task failed"
  done
  assert_equals "crew crew2" "$(crew_tabs "t$((default_cap + 1))" "t$((default_cap + 2))")" "plain crew must use herdr's default cap"
  rm -f "$config"
  pass "create_task: crew tabs fill, refill, and refuse an unreadable placement"
}

test_foreign_terminal_is_never_touched() {
  reset_hc
  add_foreign_terminal t1
  assert_equals missing "$(fm_backend_herdr_core_agent_state default:t1)" "an unlabelled terminal must read missing"
  fm_backend_herdr_core_send_key default:t1 C-c && fail "send_key must refuse an unowned terminal"
  fm_backend_herdr_core_send_text_line default:t1 hello && fail "send must refuse an unowned terminal"
  fm_backend_herdr_core_capture default:t1 10 >/dev/null && fail "capture must refuse an unowned terminal"
  fm_backend_herdr_core_kill default:t1 || fail "kill of an unowned address is a silent success"
  assert_equals "[]" "$(typed t1)" "nothing may be typed into an unowned terminal"
  assert_no_grep $'\x1fkill\x1f' "$FM_HC_LOG" "an unowned terminal must never be killed"
  assert_no_grep $'\x1frm\x1f' "$FM_HC_LOG" "an unowned terminal must never be removed"
  assert_equals live "$(jq -r '.terminals.t1.state' "$FM_HC_STATE")" "the unowned terminal must survive"
  pass "ownership: a terminal without this home's labels is never read, typed into, killed, or removed"
}

test_expected_label_binds_the_task() {
  reset_hc
  local target
  target=$(new_task t1)
  fm_backend_herdr_core_target_ready "$target" fm-t1 || fail "the owning task label must be accepted"
  fm_backend_herdr_core_target_ready "$target" fm-other && fail "another task's label must be refused"
  pass "target_ready: an expected label must match the terminal's task label"
}

test_agent_state() {
  reset_hc
  local target
  target=$(new_task t1)
  assert_equals dead "$(fm_backend_herdr_core_agent_state "$target")" "a fresh shell terminal is agent-free"
  set_terminal t2 '.foreground = {name: "zsh", argv: ["/usr/bin/zsh"], pid: 4242, cwd: "/"}'
  assert_equals dead "$(fm_backend_herdr_core_agent_state "$target")" "a shell in the foreground is agent-free"
  set_terminal t2 '.foreground = {name: "2.1.300", argv: ["claude", "--settings", "x"], pid: 4243, cwd: "/"}'
  assert_equals alive "$(fm_backend_herdr_core_agent_state "$target")" "a harness argv[0] is a live agent"
  # The spawn wraps the harness in `sh -c`, so hc reports that shell in front
  # for the agent's whole life; the harness's own status names it.
  set_terminal t2 '.foreground = {name: "sh", argv: ["/bin/sh", "-c", "codex"], pid: 4245, cwd: "/"} | .status = {app: "codex", state: "idle"}'
  assert_equals alive "$(fm_backend_herdr_core_agent_state "$target")" "an idle harness under its launch wrapper is a live agent"
  set_terminal t2 '.status = {app: "claude-code", state: "done"}'
  assert_equals alive "$(fm_backend_herdr_core_agent_state "$target")" "claude-code's status names a live agent too"
  set_terminal t2 '.status = null'
  assert_equals ambiguous "$(fm_backend_herdr_core_agent_state "$target")" "a wrapper whose harness has not reported is not proven agent-free"
  set_terminal t2 '.status = {app: "some-tool", state: "idle"}'
  assert_equals ambiguous "$(fm_backend_herdr_core_agent_state "$target")" "a status naming no harness proves nothing"
  set_terminal t2 '.foreground = {name: "node", argv: ["node", "/usr/bin/codex"], pid: 4246, cwd: "/"} | .status = {app: "codex", state: "idle"}'
  assert_equals alive "$(fm_backend_herdr_core_agent_state "$target")" "a node-bundled harness is named by its status"
  # After the spawn's worktree move the interactive login shell is not the
  # terminal's own process, so only its shape marks the return.
  set_terminal t2 '.foreground = {name: "zsh", argv: ["/usr/bin/zsh", "-i", "-l"], pid: 4247, cwd: "/"}'
  assert_equals dead "$(fm_backend_herdr_core_agent_state "$target")" "an interactive shell back in front is agent-free whatever the status says"
  set_terminal t2 '.status = null | .foreground = {name: "sleep", argv: ["sleep", "5"], pid: 4244, cwd: "/"}'
  assert_equals ambiguous "$(fm_backend_herdr_core_agent_state "$target")" "an unknown program is ambiguous"
  set_terminal t2 '.state = "finished" | .foreground = null'
  assert_equals dead "$(fm_backend_herdr_core_agent_state "$target")" "a finished terminal holds no agent"
  assert_equals unreadable "$(FM_HC_FAKE_FAIL='get' fm_backend_herdr_core_agent_state "$target")" "a failed read is unreadable"
  assert_equals missing "$(fm_backend_herdr_core_agent_state default:t9)" "an absent address is missing"
  assert_equals missing "$(fm_backend_agent_state herdr-core default:t9)" "dispatch reaches the adapter"
  pass "agent_state: alive, dead, ambiguous, unreadable, and missing from hc's foreground and status facts"
}

test_busy_state() {
  reset_hc
  local target
  target=$(new_task t1)
  set_terminal t2 '.status = {app: "claude-code", state: "working"} | .foreground = {name: "claude", argv: ["claude"], pid: 1, cwd: "/"}'
  assert_equals busy "$(fm_backend_busy_state herdr-core "$target")" "working with a harness in front is busy"
  set_terminal t2 '.foreground = {name: "sh", argv: ["/bin/sh", "-c", "claude"], pid: 1, cwd: "/"}'
  assert_equals busy "$(fm_backend_busy_state herdr-core "$target")" "working under the launch wrapper is busy"
  set_terminal t2 '.foreground = {name: "zsh", argv: ["zsh"], pid: 4242, cwd: "/"}'
  assert_equals unknown "$(fm_backend_busy_state herdr-core "$target")" "a lingering working status over the login shell is not busy"
  set_terminal t2 '.status = "done"'
  assert_equals idle "$(fm_backend_busy_state herdr-core "$target")" "done is idle"
  set_terminal t2 '.status = null'
  assert_equals unknown "$(fm_backend_busy_state herdr-core "$target")" "no reported status is unknown"
  pass "busy_state: native working is busy only with a harness, or its launch wrapper, in the foreground"
}

test_capture_and_current_path() {
  reset_hc
  local target
  target=$(new_task t1)
  set_terminal t2 '.screen = "one\ntwo\nthree"'
  assert_equals $'two\nthree' "$(fm_backend_capture herdr-core "$target" 2 fm-t1)" "capture must keep the last N lines"
  assert_equals $'one\ntwo\nthree' "$(fm_backend_visible_capture herdr-core "$target" fm-t1)" "visible capture reads the screen"
  assert_grep $'\x1fread\x1ft2\x1f--lines\x1f0' "$FM_HC_LOG" "visible capture must ask for zero history lines"
  assert_equals "$TMP_ROOT" "$(fm_backend_herdr_core_current_path "$target")" "a shell that ran nothing reports its creation cwd"
  set_terminal t2 '.foreground = {name: "bash", argv: ["bash"], pid: 1, cwd: "/srv/wt"}'
  assert_equals /srv/wt "$(fm_backend_herdr_core_current_path "$target")" "current path follows the foreground cwd"
  pass "capture, visible capture, and current path"
}

# Claude-shaped composer frames, JSON-escaped for set_terminal.
EMPTY_BOX='  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯'
HELD_BOX='  ╭────────────────────────╮\n  │ ❯ hello                │\n  ╰──────── Composer ──────╯\n\n  Enter:send'

test_send_text_submit() {
  reset_hc
  local target verdict send_log
  target=$(new_task t1)
  set_terminal t2 ".screen = \"$EMPTY_BOX\" | .after_send = [\"$EMPTY_BOX\"]"
  verdict=$(HC_TERMINAL_ID=t1 HC_SCOPE=keep fm_backend_send_text_submit herdr-core "$target" "hello world" 2 0 0 fm-t1)
  assert_equals empty "$verdict" "a landed send must verify empty"
  assert_equals '[["send","hello world"]]' "$(typed t2)" "the text must be pasted and submitted once, with no extra Enter"
  send_log=$(grep $'\x1fsend\x1f' "$FM_HC_LOG")
  assert_contains "$send_log" "HC_TERMINAL_ID= HC_SCOPE=keep" "text sends must omit the sender identity while preserving HC_SCOPE"
  reset_hc
  target=$(new_task t1)
  set_terminal t2 ".screen = \"$EMPTY_BOX\" | .after_send = [\"$HELD_BOX\"] | .after_keys = [\"$HELD_BOX\", \"$EMPTY_BOX\"]"
  verdict=$(fm_backend_send_text_submit herdr-core "$target" "hello" 3 0 0 fm-t1)
  assert_equals empty "$verdict" "a swallowed Enter must be retried until the composer clears"
  assert_equals '[["send","hello"],["keys","enter"],["keys","enter"]]' "$(typed t2)" "only Enter is retried, the text is never retyped"
  pass "send_text_submit: one paste-and-submit, Enter-only retries"
}

test_send_key_normalizes() {
  reset_hc
  local target
  target=$(new_task t1)
  fm_backend_send_key herdr-core "$target" Escape fm-t1 || fail "Escape must send"
  fm_backend_send_key herdr-core "$target" C-c fm-t1 || fail "C-c must send"
  fm_backend_send_key herdr-core "$target" C-u fm-t1 || fail "C-u must send"
  assert_equals '[["keys","esc"],["keys","ctrl+c"],["keys","ctrl+u"]]' "$(typed t2)" "keys must use hc's names"
  pass "send_key: Escape, C-c, and C-u map to hc key names"
}

test_kill() {
  reset_hc
  local target
  target=$(new_task t1)
  fm_backend_kill herdr-core "$target" "" fm-t1 || fail "killing an owned terminal must succeed"
  assert_equals null "$(jq -c '.terminals.t2' "$FM_HC_STATE")" "the owned terminal must be ended and removed"
  fm_backend_kill herdr-core "$target" "" fm-t1 || fail "an already-gone terminal is a silent success"
  target=$(new_task t1)
  set_terminal t3 '.survives = true'
  fm_backend_kill herdr-core "$target" "" fm-t1 2>/dev/null && fail "a terminal that survives its close must fail the kill"
  pass "kill: ends and removes the owned terminal, quiet when gone, loud when it survives"
}

test_finished_terminal_relaunch() {
  reset_hc
  local id=finished-relaunch project="$TMP_ROOT/relaunch-project" wt="$TMP_ROOT/relaunch-worktree" target out
  fm_git_worktree "$project" "$wt" "$id"
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/config" "$HOME_DIR/projects"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Relaunch a finished herdr-core worker.

## Firstmate spec
Exercise the relaunch behavior under test.
EOF
  target=$(HC_SESSION=lab new_task "$id")
  set_terminal t2 '.state = "finished" | .foreground = null'
  {
    printf 'window=%s\n' "$target"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\ntasktmp=%s/tasktmp\nmodel=default\neffort=default\nbackend=herdr-core\nherdr_core_session=lab\nherdr_core_terminal=t2\n' \
      "$wt" "$project" "$TMP_ROOT"
  } > "$HOME_DIR/state/$id.meta"
  mkdir -p "$TMP_ROOT/user-home"
  out=$(HOME="$TMP_ROOT/user-home" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness codex 2>&1) \
    || fail "a finished terminal must relaunch through fm-spawn.sh: $out"
  assert_equals null "$(jq -c '.terminals.t2' "$FM_HC_STATE")" "the finished terminal must be removed"
  assert_equals lab:t3 "$(fm_meta_get "$HOME_DIR/state/$id.meta" window)" "the task record must bind the replacement in its recorded session"
  assert_equals "$wt" "$(jq -r '.terminals.t3.cwd' "$FM_HC_STATE")" "the replacement must use the recorded worktree"
  assert_equals live "$(jq -r '.terminals.t3.state' "$FM_HC_STATE")" "the replacement terminal must be live"
  pass "finished terminal relaunch: replaces the exit in its recorded session and worktree"
}

test_kimi_trust_relaunch() {
  reset_hc
  local id=kimi-trust-relaunch project="$TMP_ROOT/kimi-project" wt="$TMP_ROOT/kimi-worktree" target out
  fm_git_worktree "$project" "$wt" "$id"
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/config" "$TMP_ROOT/kimi-home/.kimi-code"
  printf 'default_model = "test"\n' > "$TMP_ROOT/kimi-home/.kimi-code/config.toml"
  printf '# Task\n## Captain\047s intent\nExercise Kimi trust and delivery.\n\n## Firstmate spec\nUse the fake core endpoint.\n' > "$HOME_DIR/data/$id/brief.md"
  fm_fake_exit0 "$FAKEBIN" kimi
  target=$(HC_SESSION=lab new_task "$id")
  set_terminal t2 '.state = "finished" | .foreground = null'
  {
    printf 'window=%s\nendpoint_task_id=%s\n' "$target" "$id"
    printf 'worktree=%s\nproject=%s\nharness=kimi\nkind=ship\nmode=no-mistakes\nyolo=off\nbackend=herdr-core\nherdr_core_session=lab\nherdr_core_terminal=t2\n' "$wt" "$project"
  } > "$HOME_DIR/state/$id.meta"
  out=$(HOME="$TMP_ROOT/kimi-home" FM_SPAWN_NO_GUARD=1 \
    FM_HC_FAKE_KIMI="$ROOT/tests/captures/kimi-code-2.3.0/plain.pane" \
    FM_KIMI_READY_POLLS=4 FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness kimi 2>&1) \
    || fail "Kimi must accept trust and deliver through the retained core adapter: $out"
  assert_equals '["enter"]' "$(jq -c '[.terminals.t3.typed[] | select(.[0] == "keys") | .[1]]' "$FM_HC_STATE")" \
    "trust must receive Enter exactly once, without an extra launch or delivery Enter"
  assert_equals 1 "$(jq '[.terminals.t3.typed[] | select(.[0] == "send" and (.[1] | startswith("Read the brief at ")))] | length' "$FM_HC_STATE")" \
    "the brief must be delivered once after accepting trust"
  pass "Kimi relaunch: core sends the trust Enter and verifies brief delivery"
}

test_list_live_is_home_scoped() {
  reset_hc
  local live
  new_task t1 >/dev/null
  add_foreign_terminal t7
  set_terminal t7 '.labels = {fm_home: "someone-else", fm_task: "x"}'
  live=$(fm_backend_herdr_core_list_live)
  assert_equals "default:t2"$'\t'"fm-t1" "$live" "list_live must report only this home's terminals"
  pass "list_live: recorded-inventory discovery is scoped to this home's label"
}

test_endpoint_validation_and_absence() {
  local meta="$HOME_DIR/state/t1.meta" raw
  printf 'window=default:t2\nendpoint_task_id=t1\nworktree=/w\nproject=/p\nbackend=herdr-core\nherdr_core_session=default\nherdr_core_terminal=t2\n' > "$meta"
  fm_backend_validate_task_endpoint "$meta" t1 || fail "a consistent herdr-core record must validate"
  assert_equals default:t2 "$FM_BACKEND_VALIDATED_TARGET" "the validated target is the recorded window"
  printf 'window=default:t3\nendpoint_task_id=t1\nworktree=/w\nproject=/p\nbackend=herdr-core\nherdr_core_session=default\nherdr_core_terminal=t2\n' > "$meta"
  fm_backend_validate_task_endpoint "$meta" t1 2>/dev/null && fail "a window that disagrees with the recorded terminal must be refused"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_backend_state_verified herdr-core || fail "herdr-core must have a recovery-grade classifier"
  fm_control_backend_supports_key herdr-core Escape || fail "herdr-core must deliver Escape"
  reset_hc
  raw=$(fm_control_endpoint_absence_verdict herdr-core default:t9)
  assert_equals gone "${raw%%$'\t'*}" "a terminal the recorded session's core does not have is proven gone"
  pass "endpoint record validation, control capabilities, and absence proof"
}

test_explicit_selection() {
  assert_equals herdr-core "$(FM_BACKEND=herdr-core fm_backend_name)" "the legacy capped adapter remains explicitly selectable"
  pass "selection: explicit herdr-core keeps the fork adapter"
}

test_secondmate_spawn_refuses_herdr_core() {
  local dir out
  dir="$TMP_ROOT/secondmate-refuse"
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects"
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" FM_PROJECTS_OVERRIDE="$dir/projects" \
    "$ROOT/bin/fm-spawn.sh" sm-hc-test --secondmate --backend herdr-core 2>&1) && fail "a herdr-core secondmate spawn must be refused"
  assert_contains "$out" "does not support --secondmate" "the refusal must name the unsupported secondmate mode"
  pass "fm-spawn.sh: refuses backend=herdr-core for --secondmate spawns"
}

test_version_gate
test_create_task_labels_and_detaches
test_create_task_app_labels
test_create_task_crew_tab_cap
test_foreign_terminal_is_never_touched
test_expected_label_binds_the_task
test_agent_state
test_busy_state
test_capture_and_current_path
test_send_text_submit
test_send_key_normalizes
test_kill
test_finished_terminal_relaunch
test_kimi_trust_relaunch
test_list_live_is_home_scoped
test_endpoint_validation_and_absence
test_explicit_selection
test_secondmate_spawn_refuses_herdr_core

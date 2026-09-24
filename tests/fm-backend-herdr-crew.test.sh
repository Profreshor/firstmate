#!/usr/bin/env bash
# tests/fm-backend-herdr-crew.test.sh - portable regressions for the Herdr crew
# workspace layout (docs/herdr-backend.md "Crew workspace"): placement,
# the 3x2 grid and its fill order, cap overflow into a second crew workspace,
# exact-pane cleanup with rebalance, and a workspace disappearing with its
# last pane.
# Drives bin/backends/herdr.sh against tests/herdr-crew-fake.py, a stateful
# fake that models Herdr's split tree and layout socket, so no Herdr is needed.
# tests/fm-backend-herdr-crew-workspace-e2e.test.sh is the real-Herdr twin.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the crew fake)"; exit 0; }

herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-herdr-crew-tests)
FAKE="$ROOT/tests/herdr-crew-fake.py"
SERVERS=()
crew_cleanup() {
  local pid
  for pid in "${SERVERS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap crew_cleanup EXIT

# crew_fixture <name>: a fresh fake Herdr with one focused home workspace and
# a live layout socket. Sets DIR, HOME_DIR, FB, and exports the fake's env.
crew_fixture() {
  DIR="$TMP_ROOT/$1"
  HOME_DIR="$DIR/home"
  FB="$DIR/fakebin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$FB"
  printf '#!/usr/bin/env bash\nexec python3 %q cli "$@"\n' "$FAKE" > "$FB/herdr"
  chmod +x "$FB/herdr"
  export FM_FAKE_HERDR_STATE="$DIR/state.json"
  export FM_FAKE_HERDR_SOCKET="$DIR/s.sock"
  export FM_FAKE_HERDR_AREA=120x40
  unset FM_FAKE_HERDR_NO_LAYOUT_API
  python3 "$FAKE" serve "$FM_FAKE_HERDR_SOCKET" &
  SERVERS+=("$!")
  local i=0
  while [ ! -S "$FM_FAKE_HERDR_SOCKET" ] && [ "$i" -lt 50 ]; do sleep 0.05; i=$((i + 1)); done
  [ -S "$FM_FAKE_HERDR_SOCKET" ] || fail "fake layout socket did not start for $1"
  HOME_WS=$(herdr_fake workspace create --cwd "$DIR" --label firstmate --no-focus | jq -r '.result.workspace.workspace_id')
}

herdr_fake() { PATH="$FB:$PATH" herdr "$@" --session crewlab; }

# adapter <function> [args...]: run one adapter function as the fixture home.
adapter() {
  PATH="$FB:$PATH" FM_HOME="$HOME_DIR" HERDR_SESSION=crewlab \
    bash -c '. "$1/bin/backends/herdr.sh"; shift; "$@"' _ "$ROOT" "$@"
}

# place <label> [cap]: place one crew task; prints "<ws> <tab> <pane>".
place() {
  PATH="$FB:$PATH" FM_HOME="$HOME_DIR" HERDR_SESSION=crewlab bash -c '
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_crew_create_task crewlab "$2/state" "$2" "$3" "${4:-$FM_BACKEND_HERDR_CREW_PANE_CAP_DEFAULT}" "" || exit 1
    printf "%s %s %s\n" "$FM_BACKEND_HERDR_CREW_WORKSPACE_ID" "$FM_BACKEND_HERDR_CREW_TAB_ID" "$FM_BACKEND_HERDR_CREW_PANE_ID"
  ' _ "$ROOT" "$HOME_DIR" "$1" "${2:-}"
}

# grid <pane-in-tab>: "<label> <x> <y> <w> <h>" per pane, in layout order.
grid() {
  local layout labels
  layout=$(herdr_fake pane layout --pane "$1")
  labels=$(herdr_fake pane list)
  jq -rn --argjson layout "$layout" --argjson labels "$labels" '
    ($labels.result.panes | map({key: .pane_id, value: (.label // .pane_id)}) | from_entries) as $name
    | $layout.result.layout.panes[] | "\($name[.pane_id]) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"'
}

cell() { grid "$1" | awk -v l="$2" '$1 == l { print $2 "," $3 " " $4 "x" $5 }'; }

focused() { herdr_fake workspace list | jq -r '.result.workspaces[] | select(.focused == true) | .workspace_id'; }

# --- configuration ------------------------------------------------------------

test_preference_parses_the_crew_values() {
  local dir value got err
  dir="$TMP_ROOT/pref"; mkdir -p "$dir"
  for value in crew CREW ' crew ' 'Crew
'; do
    printf '%s' "$value" > "$dir/herdr-presentation-spaces"
    got=$(bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_presentation_preference "$2"' _ "$ROOT" "$dir")
    assert_equals crew:6 "$got" "the value '$value' should select the crew layout with the default cap of six"
  done
  printf 'crew:4' > "$dir/herdr-presentation-spaces"
  got=$(bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_presentation_preference "$2"' _ "$ROOT" "$dir")
  assert_equals crew:4 "$got" "crew:4 should set a cap of four"
  for value in crew:0 crew:17 crew:x crews; do
    printf '%s' "$value" > "$dir/herdr-presentation-spaces"
    err="$dir/err"
    got=$(bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_presentation_preference "$2"' _ "$ROOT" "$dir" 2>"$err")
    assert_equals default "$got" "the invalid value '$value' should fall back to the default"
    assert_contains "$(cat "$err")" crew "the warning for '$value' should name the crew form"
  done
  printf 'crew' > "$dir/herdr-presentation-spaces"
  if bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_presentation_enabled "$2"' _ "$ROOT" "$dir" 2>/dev/null; then
    fail "the crew layout must not also enable the one-task projection"
  fi
  pass "herdr crew: crew and crew:<1-16> select the crew layout, other values warn and fall back"
}

# --- placement ----------------------------------------------------------------

test_first_task_creates_one_recorded_crew_workspace() {
  local ws tab pane record
  crew_fixture first
  read -r ws tab pane < <(place fm-a) || fail "first crew placement failed"
  [ "$ws" != "$HOME_WS" ] || fail "a crew task must not land in the home workspace"
  assert_equals firstmate-crew "$(herdr_fake workspace list | jq -r --arg ws "$ws" '.result.workspaces[] | select(.workspace_id == $ws) | .label')" \
    "the crew workspace carries the home's crew label"
  assert_equals 1 "$(herdr_fake pane list --workspace "$ws" | jq '.result.panes | length')" \
    "the new crew workspace should hold only the task pane, with no seeded extra"
  assert_equals fm-a "$(herdr_fake pane get "$pane" | jq -r '.result.pane.label')" "the crew pane carries the task label"
  record=$(printf '%s' "$HOME_DIR"/state/.herdr-crew-workspace-*)
  assert_equals "$ws" "$(cat "$record")" "the crew workspace id is recorded in the home's state"
  assert_equals "$HOME_WS" "$(focused)" "creating the crew workspace must not move focus"
  pass "herdr crew: the first task creates and records one labeled crew workspace without moving focus"
}

test_six_tasks_fill_an_even_grid_top_row_first() {
  local i ws tab pane first_tab expected actual
  crew_fixture grid
  for i in 1 2 3 4 5 6; do
    read -r ws tab pane < <(place "fm-t$i") || fail "crew placement $i failed"
    [ -n "${first_tab:-}" ] || first_tab=$tab
    assert_equals "$first_tab" "$tab" "task $i should stay in the first crew tab"
    if [ "$i" = 3 ]; then
      assert_equals "0,0 40x40;40,0 40x40;80,0 40x40;" \
        "$(for l in fm-t1 fm-t2 fm-t3; do printf '%s;' "$(cell "$pane" "$l")"; done)" \
        "three crew tasks should be three even full-height columns"
    fi
  done
  expected="0,0 40x20;40,0 40x20;80,0 40x20;0,20 40x20;40,20 40x20;80,20 40x20;"
  actual=$(for i in 1 2 3 4 5 6; do printf '%s;' "$(cell "$pane" "fm-t$i")"; done)
  assert_equals "$expected" "$actual" "six crew tasks should fill an even 3x2 grid, top row left to right, then bottom row"
  assert_equals "$HOME_WS" "$(focused)" "filling the grid must not move focus"
  pass "herdr crew: six tasks fill an even 3x2 grid, top row left to right, then bottom row"
}

test_seventh_task_overflows_into_a_second_crew_workspace() {
  local i ws tab pane crew_ws panes=() ws2 pane7 ws8
  crew_fixture overflow
  for i in 1 2 3 4 5 6; do
    read -r ws tab pane < <(place "fm-t$i") || fail "crew placement $i failed"
    crew_ws=$ws; panes[i]=$pane
  done
  read -r ws2 tab pane7 < <(place fm-t7) || fail "seventh crew placement failed"
  assert_not_equals "$crew_ws" "$ws2" "the seventh task should open a second crew workspace once the first holds six"
  assert_equals 1 "$(herdr_fake tab list --workspace "$crew_ws" | jq '.result.tabs | length')" \
    "the full crew workspace should never gain a second tab"
  assert_equals 1 "$(herdr_fake pane list --workspace "$ws2" | jq '.result.panes | length')" \
    "the second crew workspace should hold only the seventh pane"
  assert_equals "firstmate,firstmate-crew,firstmate-crew" "$(herdr_fake workspace list | jq -r '[.result.workspaces[].label] | join(",")')" \
    "the second crew workspace carries the crew label and follows the first"
  assert_equals "$crew_ws $ws2" "$(tr '\n' ' ' < "$(printf '%s' "$HOME_DIR"/state/.herdr-crew-workspace-*)" | sed 's/ $//')" \
    "both crew workspace ids are recorded in order"
  assert_equals 7 "$(adapter fm_backend_herdr_list_live crewlab | grep -c $'\tfm-t')" "list-live should report every crew pane in both workspaces"
  adapter fm_backend_herdr_kill "crewlab:$pane7" || fail "kill of the seventh task failed"
  assert_equals dead "$(adapter fm_backend_herdr_workspace_presence_state crewlab "$ws2")" \
    "the second crew workspace should disappear with its last pane"
  assert_equals 6 "$(herdr_fake pane list --workspace "$crew_ws" | jq '.result.panes | length')" "the first crew workspace keeps its six panes"
  adapter fm_backend_herdr_kill "crewlab:${panes[2]}" || fail "kill of task 2 failed"
  read -r ws8 tab pane < <(place fm-t8) || fail "refill placement failed"
  assert_equals "$crew_ws" "$ws8" "a freed slot in the first crew workspace is refilled before another workspace opens"
  pass "herdr crew: a seventh task overflows into a second crew workspace, which goes with its last pane"
}

test_configured_cap_overflows_earlier() {
  local ws1 ws2 ws3 tab pane
  crew_fixture cap
  read -r ws1 tab pane < <(place fm-a 2) || fail "crew placement a failed"
  read -r ws2 tab pane < <(place fm-b 2) || fail "crew placement b failed"
  assert_equals "$ws1" "$ws2" "a cap of two should put two tasks in one crew workspace"
  assert_equals "0,0 60x40;60,0 60x40;" "$(cell "$pane" fm-a);$(cell "$pane" fm-b);" \
    "a cap of two should place its tasks side by side"
  read -r ws3 tab pane < <(place fm-c 2) || fail "crew placement c failed"
  assert_not_equals "$ws1" "$ws3" "a cap of two should overflow the third task into another crew workspace"
  pass "herdr crew: a configured cap changes how many panes a crew workspace holds"
}

# --- cleanup -------------------------------------------------------------------

test_kill_closes_one_pane_among_several_and_rebalances() {
  local i ws tab pane panes=() p
  crew_fixture kill-one
  for i in 1 2 3; do
    read -r ws tab pane < <(place "fm-t$i") || fail "crew placement $i failed"
    panes[i]=$pane
  done
  adapter fm_backend_herdr_kill "crewlab:${panes[2]}" || fail "kill of the middle crew pane failed"
  assert_equals dead "$(adapter fm_backend_herdr_pane_presence_state crewlab "${panes[2]}")" "the killed crew pane should be gone"
  for p in "${panes[1]}" "${panes[3]}"; do
    assert_equals present "$(adapter fm_backend_herdr_pane_presence_state crewlab "$p")" "killing one crew pane must keep its siblings"
  done
  assert_equals "0,0 60x40;60,0 60x40;" "$(cell "${panes[1]}" fm-t1);$(cell "${panes[1]}" fm-t3);" \
    "the two remaining crew panes should be rebalanced to equal halves"
  assert_equals "$HOME_WS" "$(focused)" "killing a crew pane must not move focus"
  pass "herdr crew: kill closes one exact crew pane, keeps its siblings and focus, and rebalances"
}

test_freed_slot_is_refilled() {
  local i ws tab pane panes=()
  crew_fixture refill
  for i in 1 2 3 4 5 6; do
    read -r ws tab pane < <(place "fm-t$i") || fail "crew placement $i failed"
    panes[i]=$pane
  done
  adapter fm_backend_herdr_kill "crewlab:${panes[5]}" || fail "kill of the bottom-middle crew pane failed"
  assert_equals "40,0 40x40" "$(cell "${panes[1]}" fm-t2)" "the pane above a freed slot should take its column"
  read -r ws tab pane < <(place fm-t8) || fail "refill placement failed"
  assert_equals "40,20 40x20" "$(cell "$pane" fm-t8)" "the next task should refill the freed bottom-middle slot"
  pass "herdr crew: the next task refills a freed slot and restores the grid"
}

test_last_pane_removes_the_workspace_and_next_spawn_recreates_it() {
  local ws tab pane ws2
  crew_fixture last
  read -r ws tab pane < <(place fm-a) || fail "crew placement failed"
  adapter fm_backend_herdr_kill "crewlab:$pane" || fail "kill of the last crew pane failed"
  assert_equals dead "$(adapter fm_backend_herdr_workspace_presence_state crewlab "$ws")" \
    "the crew workspace should disappear with its last pane"
  assert_equals "$HOME_WS" "$(focused)" "emptying the crew workspace must not move focus"
  read -r ws2 tab pane < <(place fm-b) || fail "placement after the crew workspace emptied failed"
  assert_not_equals "$ws" "$ws2" "a new crew workspace should be created after the old one emptied"
  assert_equals "$ws2" "$(cat "$HOME_DIR"/state/.herdr-crew-workspace-*)" "the record should follow the new crew workspace"
  pass "herdr crew: the crew workspace goes with its last pane and the next spawn recreates it"
}

# --- identity and refusal --------------------------------------------------------

test_a_relabeled_recorded_workspace_is_never_adopted() {
  local ws tab pane ws2 state
  crew_fixture relabel
  read -r ws tab pane < <(place fm-a) || fail "crew placement failed"
  state=$(jq --arg ws "$ws" '(.workspaces[] | select(.workspace_id == $ws) | .label) = "manually-renamed"' "$FM_FAKE_HERDR_STATE")
  printf '%s\n' "$state" > "$FM_FAKE_HERDR_STATE"
  read -r ws2 tab pane < <(place fm-b) || fail "placement after a relabel failed"
  assert_not_equals "$ws" "$ws2" "a recorded workspace that no longer carries the crew label must not be adopted"
  assert_equals 1 "$(herdr_fake pane list --workspace "$ws" | jq '.result.panes | length')" \
    "the relabeled workspace must be left untouched"
  pass "herdr crew: a recorded workspace whose label changed is never adopted"
}

test_a_live_same_labeled_pane_refuses() {
  local ws tab pane before state
  crew_fixture live-dup
  read -r ws tab pane < <(place fm-a) || fail "crew placement failed"
  state=$(jq --arg p "$pane" '.agents[$p] = "working"' "$FM_FAKE_HERDR_STATE")
  printf '%s\n' "$state" > "$FM_FAKE_HERDR_STATE"
  before=$(herdr_fake pane list | jq '.result.panes | length')
  if place fm-a >/dev/null 2>"$DIR/err"; then
    fail "a live same-labeled crew pane must refuse a duplicate placement"
  fi
  assert_contains "$(cat "$DIR/err")" "already exists" "the refusal should say the pane already exists"
  assert_equals "$before" "$(herdr_fake pane list | jq '.result.panes | length')" "a refused placement must create nothing"
  pass "herdr crew: a live same-labeled crew pane refuses a duplicate placement"
}

test_list_live_reports_crew_panes() {
  local ws tab pane live
  crew_fixture list-live
  place fm-a >/dev/null || fail "crew placement a failed"
  place fm-b >/dev/null || fail "crew placement b failed"
  live=$(adapter fm_backend_herdr_list_live crewlab)
  assert_contains "$live" $'\tfm-a' "list-live should report the first crew pane"
  assert_contains "$live" $'\tfm-b' "list-live should report the second crew pane"
  pass "herdr crew: list-live reports crew panes by their task labels"
}

test_missing_layout_api_still_places_with_a_warning() {
  local ws tab pane
  crew_fixture no-layout-api
  export FM_FAKE_HERDR_NO_LAYOUT_API=1
  place fm-a >/dev/null || fail "crew placement a failed"
  read -r ws tab pane < <(place fm-b 2>"$DIR/err") || fail "crew placement without the layout API failed"
  assert_contains "$(cat "$DIR/err")" "rebalance" "an unavailable rebalance should warn"
  assert_equals "0,0 60x40;60,0 60x40;" "$(cell "$pane" fm-a);$(cell "$pane" fm-b);" \
    "a two-pane split needs no rebalance to be even"
  place fm-c >/dev/null 2>&1 || fail "crew placement c failed"
  assert_equals "90,0 30x40" "$(cell "$pane" fm-c)" "without the layout API the third column keeps Herdr's plain half split of the right pane"
  unset FM_FAKE_HERDR_NO_LAYOUT_API
  pass "herdr crew: without the layout API placement still works and only the rebalance is skipped"
}

test_preference_parses_the_crew_values
test_first_task_creates_one_recorded_crew_workspace
test_six_tasks_fill_an_even_grid_top_row_first
test_seventh_task_overflows_into_a_second_crew_workspace
test_configured_cap_overflows_earlier
test_kill_closes_one_pane_among_several_and_rebalances
test_freed_slot_is_refilled
test_last_pane_removes_the_workspace_and_next_spawn_recreates_it
test_a_relabeled_recorded_workspace_is_never_adopted
test_a_live_same_labeled_pane_refuses
test_list_live_reports_crew_panes
test_missing_layout_api_still_places_with_a_warning

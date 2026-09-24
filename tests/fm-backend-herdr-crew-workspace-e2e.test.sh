#!/usr/bin/env bash
# Real-Herdr regression for the crew workspace layout (docs/herdr-backend.md
# "Crew workspace"): every task of a home becomes a split pane in a recorded
# crew workspace, filling an even 3-column by 2-row grid top row first, then
# a second crew workspace right after the first, while cleanup closes one
# exact pane, rebalances the rest, and a workspace disappears with its last
# pane.
# Every Herdr call goes through the guarded named-session lab helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-crew-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-crew-workspace)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
RECORDED_WORKTREES=""
cleanup() {
  local status=$? wt
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    env PATH="$HERDR_ORIGINAL_PATH" treehouse return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision the lab session'

# Route every adapter call through the lab helper, which alone appends the
# trailing lab session flag. The adapter's session-independent version read
# cannot pass the helper's leading-option guard, so only it goes straight to
# the real binary with the same explicit trailing lab session.
REAL_HERDR=$(command -v herdr)
export REAL_HERDR
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
printf '# lab herdr %s\n' "$(lab status --json | jq -r '"server \(.server.version) protocol \(.server.protocol), client \(.client.version) protocol \(.client.protocol)"')"

# adapter <function> [args...]: run one adapter function as this test home.
adapter() {
  # shellcheck disable=SC2016 # the inner bash expands its own positional arguments
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
    bash -c '. "$1/bin/backends/herdr.sh"; shift; "$@"' _ "$ROOT" "$@"
}

# place <label>: place one crew task with the default cap; prints "<ws> <tab> <pane>".
place() {
  # shellcheck disable=SC2016 # the inner bash expands its own positional arguments
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
    bash -c '
      . "$1/bin/backends/herdr.sh"
      fm_backend_herdr_crew_create_task "$2" "$3/state" "$3" "$4" "$FM_BACKEND_HERDR_CREW_PANE_CAP_DEFAULT" "" || exit 1
      printf "%s %s %s\n" "$FM_BACKEND_HERDR_CREW_WORKSPACE_ID" "$FM_BACKEND_HERDR_CREW_TAB_ID" "$FM_BACKEND_HERDR_CREW_PANE_ID"
    ' _ "$ROOT" "$HERDR_LAB_SESSION" "$HOME_DIR" "$1"
}

focused() { lab workspace list | jq -r '.result.workspaces[] | select(.focused == true) | .workspace_id'; }

# rects <tab>: "<pane> <x> <y> <w> <h>" per pane of that tab.
rects() {
  local pane
  pane=$(lab pane list | jq -r --arg tab "$1" '[.result.panes[] | select(.tab_id == $tab)][0].pane_id')
  lab pane layout --pane "$pane" | jq -r '.result.layout.panes[] | "\(.pane_id) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"'
}

# even <tab> <columns> <rows>: every pane is one cell of an even grid.
even() {
  local tab=$1 columns=$2 rows=$3 area
  area=$(lab pane layout --pane "$(lab pane list | jq -r --arg tab "$tab" '[.result.panes[] | select(.tab_id == $tab)][0].pane_id')" \
    | jq -c '.result.layout.area')
  rects "$tab" | awk -v c="$columns" -v r="$rows" -v area="$area" '
    BEGIN { split(area, a, /[^0-9]+/); }
    { w[NR] = $4; h[NR] = $5; n = NR }
    END {
      if (n != c * r) exit 1
      minw = w[1]; maxw = w[1]; minh = h[1]; maxh = h[1]
      for (i = 2; i <= n; i++) {
        if (w[i] < minw) minw = w[i]; if (w[i] > maxw) maxw = w[i]
        if (h[i] < minh) minh = h[i]; if (h[i] > maxh) maxh = h[i]
      }
      exit !(maxw - minw <= 2 && maxh - minh <= 2)
    }'
}

# same_widths <tab>: every pane in the tab is within two cells of the same width.
same_widths() {
  rects "$1" | awk 'NR == 1 { lo = $4; hi = $4 } { if ($4 < lo) lo = $4; if ($4 > hi) hi = $4 } END { exit !(NR > 0 && hi - lo <= 2) }'
}

cell_of() {  # <tab> <pane> -> "<x> <y>"
  rects "$1" | awk -v p="$2" '$1 == p { print $2, $3 }'
}

HOME_WS=$(lab workspace create --cwd "$ROOT" --label firstmate --no-focus | jq -er '.result.workspace.workspace_id') \
  || fail 'could not create the home workspace'
lab workspace create --cwd "$ROOT" --label other --no-focus >/dev/null || fail 'could not create a sibling workspace'
FOCUS_BEFORE=$(focused)
[ "$FOCUS_BEFORE" = "$HOME_WS" ] || fail "the lab's first workspace should be focused, got '$FOCUS_BEFORE'"

declare -a PANES
for i in 1 2 3 4 5 6; do
  read -r WS TAB "PANES[$i]" < <(place "fm-t$i") || fail "could not place crew task t$i"
  [ -n "${PANES[$i]}" ] || fail "crew task t$i returned no pane"
  if [ "$i" = 1 ]; then CREW_WS=$WS; CREW_TAB=$TAB; fi
  [ "$WS" = "$CREW_WS" ] || fail "crew task t$i landed in workspace $WS, not the crew workspace $CREW_WS"
  [ "$TAB" = "$CREW_TAB" ] || fail "crew task t$i opened tab $TAB before the first tab reached six panes"
  if [ "$i" = 3 ]; then
    even "$CREW_TAB" 3 1 || fail "three crew panes are not three even columns: $(rects "$CREW_TAB" | tr '\n' ';')"
  fi
done
[ "$(focused)" = "$FOCUS_BEFORE" ] || fail 'placing crew panes moved the focused workspace'
ORDER=$(lab workspace list | jq -r '[.result.workspaces[].label] | join(",")')
[ "$ORDER" = "firstmate,firstmate-crew,other" ] || fail "the crew workspace should sit right after the home workspace, got $ORDER"
pass 'real herdr: the first crew task creates one labeled crew workspace right after the home, without moving focus'

even "$CREW_TAB" 3 2 || fail "six crew panes are not an even 3x2 grid: $(rects "$CREW_TAB" | tr '\n' ';')"
EXPECT=""
for i in 1 2 3 4 5 6; do EXPECT="$EXPECT$(cell_of "$CREW_TAB" "${PANES[$i]}");"; done
XS=$(rects "$CREW_TAB" | awk '{print $2}' | sort -n | uniq | tr '\n' ' ')
YS=$(rects "$CREW_TAB" | awk '{print $3}' | sort -n | uniq | tr '\n' ' ')
read -r X0 X1 X2 <<<"$XS"
read -r Y0 Y1 <<<"$YS"
[ "$EXPECT" = "$X0 $Y0;$X1 $Y0;$X2 $Y0;$X0 $Y1;$X1 $Y1;$X2 $Y1;" ] \
  || fail "crew panes did not fill the top row left to right, then the bottom row: $EXPECT"
pass 'real herdr: six crew panes fill an even 3x2 grid, top row left to right, then bottom row'

read -r CREW_WS2 _ "PANES[7]" < <(place fm-t7) || fail 'could not place the seventh crew task'
[ -n "$CREW_WS2" ] && [ "$CREW_WS2" != "$CREW_WS" ] || fail "the seventh crew task should open a second crew workspace, got $CREW_WS2"
[ "$(lab tab list --workspace "$CREW_WS" | jq '.result.tabs | length')" = 1 ] || fail 'the full crew workspace should never gain a second tab'
[ "$(lab pane list --workspace "$CREW_WS2" | jq '.result.panes | length')" = 1 ] || fail 'the second crew workspace should hold exactly the seventh pane'
ORDER=$(lab workspace list | jq -r --arg c1 "$CREW_WS" --arg c2 "$CREW_WS2" \
  '[.result.workspaces[] | .workspace_id as $id | if $id == $c1 then "crew1" elif $id == $c2 then "crew2" else .label end] | join(",")')
[ "$ORDER" = "firstmate,crew1,crew2,other" ] || fail "the second crew workspace should sit right after the first, got $ORDER"
[ "$(focused)" = "$FOCUS_BEFORE" ] || fail 'opening the second crew workspace moved the focused workspace'
pass 'real herdr: a seventh crew task opens a second crew workspace right after the first, without moving focus'

LIVE=$(adapter fm_backend_herdr_list_live "$HERDR_LAB_SESSION")
[ "$(printf '%s\n' "$LIVE" | grep -c $'\tfm-t')" = 7 ] || fail "list-live should report all seven crew panes, got: $LIVE"
pass 'real herdr: list-live discovers crew panes by their task labels'

adapter fm_backend_herdr_kill "$HERDR_LAB_SESSION:${PANES[5]}" || fail 'kill of one crew pane failed'
[ "$(adapter fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "${PANES[5]}")" = dead ] || fail 'the killed crew pane is still present'
for i in 1 2 3 4 6 7; do
  [ "$(adapter fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "${PANES[$i]}")" = present ] \
    || fail "killing one crew pane removed a sibling pane t$i"
done
[ "$(focused)" = "$FOCUS_BEFORE" ] || fail 'killing a crew pane moved the focused workspace'
same_widths "$CREW_TAB" || fail "remaining crew columns are uneven after a close: $(rects "$CREW_TAB" | tr '\n' ';')"
pass 'real herdr: killing one crew pane closes only that pane and keeps focus'

read -r WS TAB "PANES[8]" < <(place fm-t8) || fail 'could not refill the crew grid'
[ "$TAB" = "$CREW_TAB" ] || fail "the freed slot should be refilled in the first tab, got $TAB"
even "$CREW_TAB" 3 2 || fail "refilling the freed slot did not restore an even 3x2 grid: $(rects "$CREW_TAB" | tr '\n' ';')"
[ "$(cell_of "$CREW_TAB" "${PANES[8]}")" = "$X1 $Y1" ] || fail 'the refill should take the freed bottom-middle slot'
pass 'real herdr: the next crew task refills the freed slot and restores the even grid'

read -r WS TAB PANE_DUP < <(place fm-t1) || fail 'a same-labeled agent-free crew pane should be replaced'
[ "$(adapter fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "${PANES[1]}")" = dead ] \
  || fail 'the replaced same-labeled husk pane is still present'
PANES[1]=$PANE_DUP
pass 'real herdr: a same-labeled agent-free crew pane is replaced only after its successor exists'

# Closing the whole right column leaves two columns Herdr would draw as one
# third and two thirds; the rebalance after each close evens them.
adapter fm_backend_herdr_kill "$HERDR_LAB_SESSION:${PANES[3]}" || fail 'kill of crew task t3 failed'
adapter fm_backend_herdr_kill "$HERDR_LAB_SESSION:${PANES[6]}" || fail 'kill of crew task t6 failed'
[ "$(rects "$CREW_TAB" | awk '{print $2}' | sort -u | wc -l)" = 2 ] || fail "closing the right column should leave two columns: $(rects "$CREW_TAB" | tr '\n' ';')"
same_widths "$CREW_TAB" || fail "the two remaining crew columns were not rebalanced: $(rects "$CREW_TAB" | tr '\n' ';')"
pass 'real herdr: closing a whole crew column rebalances the remaining columns evenly'

for i in 1 2 4 7 8; do
  adapter fm_backend_herdr_kill "$HERDR_LAB_SESSION:${PANES[$i]}" || fail "kill of crew task t$i failed"
done
[ "$(adapter fm_backend_herdr_workspace_presence_state "$HERDR_LAB_SESSION" "$CREW_WS")" = dead ] \
  || fail 'the crew workspace should disappear with its last pane'
[ "$(adapter fm_backend_herdr_workspace_presence_state "$HERDR_LAB_SESSION" "$CREW_WS2")" = dead ] \
  || fail 'the second crew workspace should disappear with its last pane'
[ "$(focused)" = "$FOCUS_BEFORE" ] || fail 'emptying the crew workspace moved the focused workspace'
read -r WS TAB _ < <(place fm-t9) || fail 'could not place a crew task after the crew workspace emptied'
[ -n "$WS" ] && [ "$WS" != "$CREW_WS" ] || fail 'a new crew workspace should be created after the old one emptied'
[ "$(lab workspace list | jq -r '[.result.workspaces[].label] | join(",")')" = "firstmate,firstmate-crew,other" ] \
  || fail 'the recreated crew workspace should again sit right after the home'
pass 'real herdr: each crew workspace disappears with its last pane and the next spawn recreates one'

# The same layout through the real spawn and teardown scripts: a home whose
# config selects "crew" gets its crewmates as panes of one crew workspace, and
# teardown closes each exact pane.
if ! command -v treehouse >/dev/null 2>&1; then
  echo 'skip: treehouse not found; the real spawn and teardown pass needs it'
  exit 0
fi
SPAWN_HOME="$TMP_ROOT/spawn-home"
PROJECT_DIR="$TMP_ROOT/project"
mkdir -p "$SPAWN_HOME/state" "$SPAWN_HOME/config" "$PROJECT_DIR"
touch "$SPAWN_HOME/state/.last-watcher-beat"
printf 'crew\n' > "$SPAWN_HOME/config/herdr-presentation-spaces"
git -C "$PROJECT_DIR" init -q
printf '# Herdr crew E2E fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT_DIR" "$PROJECT_DIR.origin.git"
git -C "$PROJECT_DIR" remote add origin "file://$PROJECT_DIR.origin.git"

spawn_task() {  # <id>
  mkdir -p "$SPAWN_HOME/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nCrew fixture %s.\n\n## Firstmate spec\nNone.\n' "$1" > "$SPAWN_HOME/data/$1/brief.md"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJECT_DIR" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}
teardown_task() {  # <id>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
    "$ROOT/bin/fm-teardown.sh" "$1" --force
}
meta() { grep "^$2=" "$SPAWN_HOME/state/$1.meta" | cut -d= -f2-; }

for id in crew-a crew-b; do
  spawn_task "$id" > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" || fail "real crew spawn $id failed: $(cat "$TMP_ROOT/$id.err")"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}$(meta "$id" worktree)"$'\n'
done
[ "$(meta crew-a herdr_workspace_id)" = "$(meta crew-b herdr_workspace_id)" ] \
  && [ "$(meta crew-a herdr_tab_id)" = "$(meta crew-b herdr_tab_id)" ] \
  && [ "$(meta crew-a herdr_pane_id)" != "$(meta crew-b herdr_pane_id)" ] \
  || fail 'two real crew spawns should be two panes of one crew tab'
SPAWN_WS=$(meta crew-a herdr_workspace_id)
[ "$(lab workspace list | jq -r --arg ws "$SPAWN_WS" '.result.workspaces[] | select(.workspace_id == $ws) | .label')" = firstmate-crew ] \
  || fail 'the real crew spawns did not land in a labeled crew workspace'
[ ! -e "$SPAWN_HOME/state/crew-a.herdr-presentation" ] || fail 'a crew spawn must not write a presentation journal'
pass 'real herdr: real spawns on the crew setting become panes of one crew workspace'

PANE_B=$(meta crew-b herdr_pane_id)
teardown_task crew-a > "$TMP_ROOT/td-a.out" 2> "$TMP_ROOT/td-a.err" || fail "real crew teardown failed: $(cat "$TMP_ROOT/td-a.err")"
[ "$(adapter fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$PANE_B")" = present ] \
  || fail 'tearing down one real crew task closed its sibling pane'
teardown_task crew-b > "$TMP_ROOT/td-b.out" 2> "$TMP_ROOT/td-b.err" || fail "real crew teardown failed: $(cat "$TMP_ROOT/td-b.err")"
[ "$(adapter fm_backend_herdr_workspace_presence_state "$HERDR_LAB_SESSION" "$SPAWN_WS")" = dead ] \
  || fail 'the crew workspace should disappear when its last real task is torn down'
pass 'real herdr: real teardown closes one exact crew pane and the workspace goes with the last one'

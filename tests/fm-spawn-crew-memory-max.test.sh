#!/usr/bin/env bash
# tests/fm-spawn-crew-memory-max.test.sh - config/crew-memory-max runs every
# launch inside a memory-capped systemd user scope under fm-crew.slice.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane, then EXECUTE the launch command the pane received with
# systemd-run and the harness replaced by probes, so what the probes record is
# what a real launch would have asked systemd for and started.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-crew-memory-max)

# make_case <name> <id> - sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG.
make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  LAUNCH_LOG="$case_dir/launch.log"
  PANE_LOG="$case_dir/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
}

run_spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# A systemd-run probe that records its arguments and runs the command after --,
# and a harness probe that reports it started.
install_probes() {
  cat > "$FAKEBIN_DIR/systemd-run" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$SYSTEMD_RUN_ARGS"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
SH
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
echo harness-started
SH
  chmod +x "$FAKEBIN_DIR/systemd-run" "$FAKEBIN_DIR/codex"
}

execute_launch() {
  SYSTEMD_RUN_ARGS="$1" env PATH="$FAKEBIN_DIR:$PATH" HOME="$TMP_ROOT/pane-home" \
    SYSTEMD_RUN_ARGS="$1" /bin/sh -c "$(cat "$LAUNCH_LOG")"
}

test_capped_launch_runs_inside_the_scope() {
  local out status seen args
  make_case capped capped-a1
  install_probes
  printf '6G\n' > "$HOME_DIR/config/crew-memory-max"
  out=$(PATH="$FAKEBIN_DIR:$PATH" run_spawn capped-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a capped spawn should succeed: $out"
  args="$TMP_ROOT/capped/systemd-run.args"
  seen=$(execute_launch "$args") || fail "the capped launch failed to run"
  assert_equals harness-started "$seen" "the harness must start inside the scope"
  assert_contains "$(cat "$args")" "--slice=fm-crew.slice" "the scope must sit under fm-crew.slice"
  assert_contains "$(cat "$args")" "MemoryMax=6G" "the scope must carry the configured cap"
  assert_contains "$(cat "$args")" "--user" "the scope must belong to the user manager"
  pass "a configured cap launches the harness inside a capped fm-crew.slice scope"
}

test_absent_file_launches_unwrapped() {
  local out status seen args
  make_case absent absent-a1
  install_probes
  out=$(run_spawn absent-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an uncapped spawn should succeed: $out"
  args="$TMP_ROOT/absent/systemd-run.args"
  seen=$(execute_launch "$args") || fail "the uncapped launch failed to run"
  assert_equals harness-started "$seen" "the harness must still start"
  [ ! -e "$args" ] || fail "an absent config/crew-memory-max must not route the launch through systemd-run"
  pass "with no config/crew-memory-max the launch is unchanged"
}

test_malformed_value_refuses() {
  local out status
  make_case malformed malformed-a1
  install_probes
  printf 'lots\n' > "$HOME_DIR/config/crew-memory-max"
  out=$(PATH="$FAKEBIN_DIR:$PATH" run_spawn malformed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed cap must refuse the spawn"
  assert_contains "$out" "config/crew-memory-max" "the refusal must name the file to fix"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must not deliver a launch"
  pass "a malformed config/crew-memory-max refuses before launching"
}

test_capped_launch_runs_inside_the_scope
test_absent_file_launches_unwrapped
test_malformed_value_refuses

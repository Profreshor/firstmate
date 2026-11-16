#!/usr/bin/env bash
# Behavior tests for bin/fm-rebase-needed.sh: each scenario builds a local
# origin and a feature clone (nothing is pushed anywhere) and asserts the
# one-line verdict the script prints.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rebase-needed)
TOOL="$ROOT/bin/fm-rebase-needed.sh"

# new_world <name>: origin (main with f1, f2) plus a clone on branch feat.
new_world() {
  local w="$TMP_ROOT/$1"
  git init -q -b main "$w/origin"
  git -C "$w/origin" config user.email t@example.com
  git -C "$w/origin" config user.name t
  printf 1 > "$w/origin/f1"; printf 1 > "$w/origin/f2"
  git -C "$w/origin" add -A && git -C "$w/origin" commit -q -m base
  git clone -q "$w/origin" "$w/work"
  git -C "$w/work" config user.email t@example.com
  git -C "$w/work" config user.name t
  git -C "$w/work" checkout -q -b feat
  printf 2 > "$w/work/f1"
  git -C "$w/work" commit -qam feature
  printf '%s' "$w"
}

on_main() {  # <world> <file> <content> [subdir]
  mkdir -p "$1/origin/$(dirname "$2")"
  printf '%s' "$3" > "$1/origin/$2"
  git -C "$1/origin" add -A && git -C "$1/origin" commit -q -m "main $2"
}

verdict() { ( cd "$1/work" && "$TOOL" "${2:-}" ) 2>&1; }

expect() {  # <world> <prefix> <label> [base-arg]
  local out
  out=$(verdict "$1" "${4:-main}")
  case "$out" in "$2"*) [ -n "${QUIET:-}" ] || pass "$3" ;; *) fail "$3: got '$out'" ;; esac
}

test_main_not_moved() {
  expect "$(new_world a)" "skip-rebase: origin/main has not moved" "main not moved skips"
}
test_unrelated_file() {
  local w; w=$(new_world b); on_main "$w" other x
  expect "$w" "skip-rebase: no conflict and no file changed" "unrelated main change skips"
}
test_same_file_no_conflict() {
  local w; w=$(new_world c); on_main "$w" f2 changed
  git -C "$w/work" mv f2 f2b 2>/dev/null; git -C "$w/work" commit -qm rename
  expect "$w" "normal: origin/main also changed" "rename vs edit counts as overlap"
}
test_stale_main_conflict() {
  local w; w=$(new_world d); on_main "$w" f1 3
  expect "$w" "normal: conflicts with origin/main" "real conflict rebases"
}
test_unpushed_branch() {
  expect "$(new_world unpushed)" "skip-rebase: origin/main has not moved" "missing remote branch skips"
}
test_remote_branch_read_error() {
  local w git_path
  w=$(new_world branch-read-error)
  git_path=$(command -v git)
  mkdir -p "$w/fake-bin"
  printf '#!/usr/bin/env bash\n[ "$1" = ls-remote ] && exit 1\nexec %q "$@"\n' "$git_path" > "$w/fake-bin/git"
  chmod +x "$w/fake-bin/git"
  PATH="$w/fake-bin:$PATH" expect "$w" "normal: could not read origin/feat" "remote branch read error rebases"
}
test_pushed_branch_ahead() {
  local w; w=$(new_world e)
  git -C "$w/work" push -q origin feat
  git -C "$w/origin" checkout -q feat
  printf 9 > "$w/origin/pipeline"; git -C "$w/origin" add -A; git -C "$w/origin" commit -q -m fix
  git -C "$w/origin" checkout -q main
  expect "$w" "normal: origin/feat has commits HEAD lacks" "pipeline commits on pushed branch rebase"
  git -C "$w/work" pull -q --ff-only origin feat
  QUIET=1 expect "$w" "skip-rebase" "skips again once synced"
}
test_detached_head() {
  local w; w=$(new_world f); git -C "$w/work" checkout -q --detach
  expect "$w" "normal: detached HEAD" "detached HEAD rebases"
}
test_numbered_clash() {
  local w; w=$(new_world g)
  on_main "$w" db/sql/031_a.sql a
  mkdir -p "$w/work/db/sql"; printf b > "$w/work/db/sql/031_b.sql"
  git -C "$w/work" add -A; git -C "$w/work" commit -qm mig
  QUIET=1 expect "$w" "normal: both sides added numbered file(s): db/sql/031" "same migration number rebases"
  git -C "$w/work" mv db/sql/031_b.sql db/sql/032_b.sql; git -C "$w/work" commit -qm renum
  expect "$w" "skip-rebase" "different migration numbers skip"
}
test_fetch_error() {
  local w; w=$(new_world h)
  expect "$w" "normal: could not fetch" "unknown base falls back to normal" nosuchbase
}

fm_test_run test_main_not_moved test_unrelated_file test_same_file_no_conflict test_stale_main_conflict \
  test_unpushed_branch test_remote_branch_read_error test_pushed_branch_ahead \
  test_detached_head test_numbered_clash test_fetch_error

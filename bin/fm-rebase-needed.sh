#!/usr/bin/env bash
# Run in the worker's checkout right before `no-mistakes axi run`.
# Prints "skip-rebase: <why>" when the run may pass --skip rebase, otherwise
# "normal: <why>". Any doubt or git error answers "normal" (today's behaviour).
set -u
base=${1:-main}; up="origin/$base"
br=$(git symbolic-ref -q --short HEAD) || { echo "normal: detached HEAD"; exit 0; }
git fetch -q origin "$base" 2>/dev/null || { echo "normal: could not fetch $up"; exit 0; }
# The pipeline's rebase step also syncs pipeline-made commits from the pushed branch.
if git fetch -q origin "$br" 2>/dev/null && ! git merge-base --is-ancestor "origin/$br" HEAD; then
  echo "normal: origin/$br has commits HEAD lacks"; exit 0
fi
mb=$(git merge-base HEAD "$up") || { echo "normal: no merge base with $up"; exit 0; }
[ "$mb" = "$(git rev-parse "$up")" ] && { echo "skip-rebase: $up has not moved"; exit 0; }
git merge-tree --write-tree --name-only HEAD "$up" >/dev/null 2>&1 || { echo "normal: conflicts with $up"; exit 0; }
overlap=$(comm -12 <(git diff --no-renames --name-only "$mb" "$up" | sort -u) \
                   <(git diff --no-renames --name-only "$mb" HEAD | sort -u))
[ -n "$overlap" ] && { echo "normal: $up also changed: $(echo $overlap)"; exit 0; }
# Numbered files (e.g. migrate/sql/031_x.sql) added on both sides in one directory.
seq_key() { git diff --no-renames --diff-filter=A --name-only "$@" | sed -nE 's#^(.*/)?([0-9]+)[_-][^/]*$#\1\2#p' | sort -u; }
clash=$(comm -12 <(seq_key "$mb" "$up") <(seq_key "$mb" HEAD))
[ -n "$clash" ] && { echo "normal: both sides added numbered file(s): $(echo $clash)"; exit 0; }
echo "skip-rebase: no conflict and no file changed on both sides"

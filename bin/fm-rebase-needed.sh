#!/usr/bin/env bash
# Run in the worker's checkout right before `no-mistakes axi run`.
# Prints "skip-rebase: <why>" when the run may pass --skip rebase, otherwise
# "normal: <why>". Any doubt or git error answers "normal" (today's behaviour).
set -u
base=${1:-main}; up="origin/$base"
br=$(git symbolic-ref -q --short HEAD) || { echo "normal: detached HEAD"; exit 0; }
git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null || { echo "normal: could not fetch $up"; exit 0; }
# The pipeline's rebase step also syncs pipeline-made commits from the pushed branch.
if git ls-remote --exit-code --heads origin "refs/heads/$br" >/dev/null 2>&1; then
  git fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null || { echo "normal: could not fetch origin/$br"; exit 0; }
  if ! git merge-base --is-ancestor "origin/$br" HEAD; then
    echo "normal: origin/$br has commits HEAD lacks"; exit 0
  fi
elif [ "$?" -ne 2 ]; then
  echo "normal: could not read origin/$br"; exit 0
fi
mb=$(git merge-base HEAD "$up") || { echo "normal: no merge base with $up"; exit 0; }
base_tip=$(git rev-parse "$up") || { echo "normal: could not resolve $up"; exit 0; }
[ "$mb" = "$base_tip" ] && { echo "skip-rebase: $up has not moved"; exit 0; }
git merge-tree --write-tree --name-only HEAD "$up" >/dev/null 2>&1 || { echo "normal: conflicts with $up"; exit 0; }
base_changes=$(git diff --no-renames --name-only "$mb" "$up") || { echo "normal: could not compare files with $up"; exit 0; }
head_changes=$(git diff --no-renames --name-only "$mb" HEAD) || { echo "normal: could not compare files with HEAD"; exit 0; }
overlap=$(comm -12 <(printf '%s\n' "$base_changes" | sort -u) \
                   <(printf '%s\n' "$head_changes" | sort -u))
[ -n "$overlap" ] && { echo "normal: $up also changed: $(echo $overlap)"; exit 0; }
# Numbered files (e.g. migrate/sql/031_x.sql) added on both sides in one directory.
seq_key() { sed -nE 's#^(.*/)?([0-9]+)[_-][^/]*$#\1\2#p' <<< "$1" | sort -u; }
base_added=$(git diff --no-renames --diff-filter=A --name-only "$mb" "$up") || { echo "normal: could not compare additions with $up"; exit 0; }
head_added=$(git diff --no-renames --diff-filter=A --name-only "$mb" HEAD) || { echo "normal: could not compare additions with HEAD"; exit 0; }
clash=$(comm -12 <(seq_key "$base_added") <(seq_key "$head_added"))
[ -n "$clash" ] && { echo "normal: both sides added numbered file(s): $(echo $clash)"; exit 0; }
echo "skip-rebase: no conflict and no file changed on both sides"

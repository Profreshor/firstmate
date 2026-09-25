#!/usr/bin/env bash
# fm-secrets.sh - the only worker-facing interface for inspecting settings.
#
# Subcommands:
#   names <env-file>
#       Print only assignment names, one per line.
#   has <env-file> <NAME>...
#   has --service <systemd-unit> <NAME>...
#       Print NAME=yes, NAME=no, or NAME=unknown without any setting value.
#       A running service's main-process environment is authoritative when it
#       is readable; otherwise the unit's EnvironmentFile= and Environment=
#       declarations are inspected. Values that could come from another
#       systemd environment source are reported as unknown rather than read.
#   run <env-file> --only NAME[,NAME...] -- <command...>
#       Inherit only PATH, HOME, USER, LOGNAME, LANG, LC_*, TERM, TMPDIR, SHELL,
#       and PWD, add only the selected names, run the command, and scrub its
#       The command has no controlling terminal and reads stdin from /dev/null.
#       stdout and stderr. Every nonempty selected value and every other file
#       value at least 6 bytes long is replaced with <redacted:NAME>. Values of
#       PASS, PWD, SECRET, TOKEN, KEY, PIN,
#       CREDENTIAL, or AUTH settings and URL userinfo passwords are scrubbed at
#       any length. Other values shorter than 6 bytes are deliberately not
#       scrubbed because replacing common short strings would corrupt ordinary
#       output.
#       The child's exit status is preserved.
#
# Env files accept leading whitespace, an optional export prefix, comments,
# matching single or double quotes, and quoted values that span lines.
# Mechanics and limits are owned by this help text; worker briefs point here.
#
# Usage:
#   fm-secrets.sh names <env-file>
#   fm-secrets.sh has <env-file> <NAME>...
#   fm-secrets.sh has --service <systemd-unit> <NAME>...
#   fm-secrets.sh run <env-file> --only NAME[,NAME...] -- <command...>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "fm-secrets: python3 is required" >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/fm-secrets.py" "$@"

#!/usr/bin/env python3
"""Implementation for fm-secrets.sh.

The shell entry point owns the public help and invocation contract. This helper
keeps secret-bearing data inside one process and never includes a value in an
error or diagnostic.
Byte-exact parsing and scrubbing deliberately use Python, following existing bin-helper precedent.
"""

from __future__ import annotations

import glob
import os
import re
import shlex
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence
from urllib.parse import unquote_to_bytes


NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ASSIGNMENT_RE = re.compile(
    r"[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*"
)
SYSTEMD_ASSIGNMENT_RE = re.compile(r"[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*")
URL_PASSWORD_RE = re.compile(
    rb"([A-Za-z][A-Za-z0-9+.-]*://[^\s/@:]*:)([^\s/@]+)(@[^\s]+)"
)
MIN_SCRUB_BYTES = 6
SECRET_NAME_RE = re.compile(r"PASS|PWD|SECRET|TOKEN|KEY|PIN|CREDENTIAL|AUTH", re.IGNORECASE)


class SecretToolError(Exception):
    """An error whose message is guaranteed not to contain a setting value."""


@dataclass(frozen=True)
class Assignment:
    name: str
    value: str


def _line_end(text: str, start: int) -> int:
    end = text.find("\n", start)
    return len(text) if end < 0 else end


def _line_number(text: str, position: int) -> int:
    return text.count("\n", 0, position) + 1


def _decode_double_quoted(raw: str) -> str:
    decoded: list[str] = []
    index = 0
    escapes = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"'}
    while index < len(raw):
        char = raw[index]
        if char == "\\" and index + 1 < len(raw):
            following = raw[index + 1]
            if following in escapes:
                decoded.append(escapes[following])
                index += 2
                continue
        decoded.append(char)
        index += 1
    return "".join(decoded)


def _quoted_value(text: str, start: int, quote: str, path: str) -> tuple[str, int]:
    cursor = start + 1
    raw: list[str] = []
    while cursor < len(text):
        char = text[cursor]
        if char == quote:
            if quote == '"':
                backslashes = 0
                check = cursor - 1
                while check >= start and text[check] == "\\":
                    backslashes += 1
                    check -= 1
                if backslashes % 2:
                    raw.append(char)
                    cursor += 1
                    continue
            value = "".join(raw)
            if quote == '"':
                value = _decode_double_quoted(value)
            return value, cursor + 1
        raw.append(char)
        cursor += 1
    raise SecretToolError(
        f"{path}: unterminated quoted value at line {_line_number(text, start)}"
    )


def _strip_unquoted_comment(value: str) -> str:
    for index, char in enumerate(value):
        if char == "#" and (index == 0 or value[index - 1].isspace()):
            return value[:index].rstrip()
    return value.rstrip()


def _unquoted_value(text: str, start: int) -> tuple[str, int]:
    pieces: list[str] = []
    cursor = start
    while True:
        end = _line_end(text, cursor)
        piece = text[cursor:end]
        trimmed = piece.rstrip()
        trailing = len(trimmed) - len(trimmed.rstrip("\\"))
        if trailing % 2 == 1 and end < len(text):
            pieces.append(trimmed[:-1])
            cursor = end + 1
            continue
        pieces.append(piece)
        return _strip_unquoted_comment("".join(pieces)), end


def parse_env_file(path: str) -> list[Assignment]:
    try:
        text = Path(path).read_text(encoding="utf-8", errors="surrogateescape")
    except OSError as exc:
        raise SecretToolError(f"cannot read settings file: {path}") from exc

    assignments: list[Assignment] = []
    position = 0
    while position < len(text):
        end = _line_end(text, position)
        line = text[position:end]
        stripped = line.lstrip(" \t\r")
        if not stripped or stripped.startswith("#"):
            position = end + (end < len(text))
            continue

        match = ASSIGNMENT_RE.match(line)
        if match is None:
            position = end + (end < len(text))
            continue

        value_start = position + match.end()
        if value_start < len(text) and text[value_start] in ("'", '"'):
            value, consumed = _quoted_value(
                text, value_start, text[value_start], path
            )
            next_end = _line_end(text, consumed)
            trailing = text[consumed:next_end].strip(" \t\r")
            if trailing and not trailing.startswith("#"):
                raise SecretToolError(
                    f"{path}: trailing data after quoted value at line {_line_number(text, consumed)}"
                )
        else:
            value, next_end = _unquoted_value(text, value_start)
        assignments.append(Assignment(match.group(1), value))
        position = next_end + (next_end < len(text))
    return assignments


def _systemd_unquoted_value(text: str, start: int, path: str) -> tuple[str, int]:
    pieces: list[str] = []
    cursor = start
    while True:
        end = _line_end(text, cursor)
        piece = text[cursor:end].rstrip(" \t\r")
        trailing = len(piece) - len(piece.rstrip("\\"))
        if trailing % 2 and end < len(text):
            pieces.append(piece[:-1])
            cursor = end + 1
            continue
        pieces.append(piece)
        break
    value = "".join(pieces)
    decoded: list[str] = []
    cursor = 0
    while cursor < len(value):
        if value[cursor] == "\\":
            if cursor + 1 == len(value):
                raise SecretToolError(f"{path}: invalid unquoted escape")
            cursor += 1
        decoded.append(value[cursor])
        cursor += 1
    return "".join(decoded), end


def _systemd_double_quoted_value(text: str, start: int, path: str) -> tuple[str, int]:
    decoded: list[str] = []
    cursor = start + 1
    while cursor < len(text):
        char = text[cursor]
        if char == '"':
            return "".join(decoded), cursor + 1
        if char == "\\" and cursor + 1 < len(text):
            following = text[cursor + 1]
            if following == "\n":
                cursor += 2
                continue
            if following in '"\\`$':
                decoded.append(following)
                cursor += 2
                continue
        decoded.append(char)
        cursor += 1
    raise SecretToolError(f"{path}: unterminated double-quoted value")


def parse_systemd_environment_file(path: str) -> list[Assignment]:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise SecretToolError("systemd EnvironmentFile is not valid UTF-8") from exc
    except OSError as exc:
        raise SecretToolError(f"cannot read settings file: {path}") from exc
    if any(
        char == "\0"
        or char == "\ufeff"
        or 0xFDD0 <= ord(char) <= 0xFDEF
        or ord(char) & 0xFFFF in {0xFFFE, 0xFFFF}
        for char in text
    ):
        raise SecretToolError("systemd EnvironmentFile contains disallowed characters")

    assignments: list[Assignment] = []
    position = 0
    while position < len(text):
        end = _line_end(text, position)
        line = text[position:end]
        stripped = line.lstrip(" \t\r")
        if not stripped or stripped.startswith(("#", ";")):
            position = end + (end < len(text))
            continue
        match = SYSTEMD_ASSIGNMENT_RE.match(line)
        if match is None:
            position = end + (end < len(text))
            continue
        value_start = position + match.end()
        if value_start < len(text) and text[value_start] == "'":
            value, consumed = _quoted_value(text, value_start, "'", path)
        elif value_start < len(text) and text[value_start] == '"':
            value, consumed = _systemd_double_quoted_value(text, value_start, path)
        else:
            value, consumed = _systemd_unquoted_value(text, value_start, path)
        trailing_end = _line_end(text, consumed)
        if text[consumed:trailing_end].strip(" \t\r"):
            raise SecretToolError("systemd EnvironmentFile has unsupported trailing data")
        assignments.append(Assignment(match.group(1), value))
        position = trailing_end + (trailing_end < len(text))
    return assignments


def unique_names(assignments: Iterable[Assignment]) -> list[str]:
    seen: set[str] = set()
    names: list[str] = []
    for assignment in assignments:
        if assignment.name not in seen:
            seen.add(assignment.name)
            names.append(assignment.name)
    return names


def final_values(assignments: Iterable[Assignment]) -> dict[str, str]:
    return {assignment.name: assignment.value for assignment in assignments}


def is_secret_name(name: str) -> bool:
    return SECRET_NAME_RE.search(name) is not None


def validate_names(names: Sequence[str]) -> None:
    if not names:
        raise SecretToolError("at least one setting name is required")
    for name in names:
        if NAME_RE.fullmatch(name) is None:
            raise SecretToolError(f"invalid setting name: {name}")


def systemctl_property(unit: str, property_name: str) -> str:
    try:
        result = subprocess.run(
            [
                "systemctl",
                "show",
                "--no-pager",
                f"--property={property_name}",
                "--value",
                "--",
                unit,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
    except OSError as exc:
        raise SecretToolError("systemctl is unavailable") from exc
    if result.returncode != 0:
        raise SecretToolError(f"cannot inspect systemd unit: {unit}")
    return result.stdout.strip()


def process_environment_names(pid_text: str) -> set[str] | None:
    if not pid_text.isdigit() or pid_text == "0":
        return None
    try:
        environ = Path(f"/proc/{pid_text}/environ").read_bytes()
    except OSError:
        return None
    names: set[str] = set()
    for field in environ.split(b"\0"):
        raw_name, separator, _value = field.partition(b"=")
        if not separator:
            continue
        try:
            name = raw_name.decode("ascii")
        except UnicodeDecodeError:
            continue
        if NAME_RE.fullmatch(name):
            names.add(name)
    return names


def environment_declaration_assignments(raw: str) -> list[Assignment]:
    try:
        words = shlex.split(raw, posix=True)
    except ValueError as exc:
        raise SecretToolError("systemd Environment= data could not be parsed safely") from exc
    assignments: list[Assignment] = []
    for word in words:
        name, separator, value = word.partition("=")
        if separator and NAME_RE.fullmatch(name):
            assignments.append(Assignment(name, value))
    return assignments


def unset_environment_assignments(raw: str) -> list[tuple[str, str | None]]:
    try:
        words = shlex.split(raw, posix=True)
    except ValueError as exc:
        raise SecretToolError("systemd UnsetEnvironment= data could not be parsed safely") from exc
    unsets: list[tuple[str, str | None]] = []
    for word in words:
        name, separator, value = word.partition("=")
        if NAME_RE.fullmatch(name):
            unsets.append((name, value if separator else None))
    return unsets


def environment_file_specs(raw: str) -> list[tuple[str, bool]]:
    try:
        words = shlex.split(raw, posix=True)
    except ValueError as exc:
        raise SecretToolError("systemd EnvironmentFile= data could not be parsed safely") from exc
    specs: list[tuple[str, bool]] = []
    for word in words:
        if word.startswith("(ignore_errors="):
            if specs and word == "(ignore_errors=yes)":
                path, _ignore_errors = specs[-1]
                specs[-1] = (path, True)
            continue
        ignore_errors = False
        if word.startswith("-"):
            word = word[1:]
            ignore_errors = True
        if word:
            specs.extend((path, ignore_errors) for path in (glob.glob(word) or [word]))
    return specs


def service_presence(unit: str, requested: Sequence[str]) -> dict[str, str]:
    if not unit or unit.startswith("-"):
        raise SecretToolError("a valid systemd unit name is required")
    running = process_environment_names(systemctl_property(unit, "MainPID"))
    if running is not None:
        return {name: "yes" if name in running else "no" for name in requested}

    assignments = environment_declaration_assignments(
        systemctl_property(unit, "Environment")
    )
    files = environment_file_specs(systemctl_property(unit, "EnvironmentFiles"))
    for path, ignore_errors in files:
        try:
            assignments.extend(parse_systemd_environment_file(path))
        except SecretToolError as exc:
            if ignore_errors:
                continue
            raise SecretToolError(
                "cannot inspect a required systemd EnvironmentFile safely"
            ) from exc
    unsets = unset_environment_assignments(
        systemctl_property(unit, "UnsetEnvironment")
    )
    values = {assignment.name: assignment.value for assignment in assignments}
    present = {
        name
        for name, value in values.items()
        if not any(
            name == unset_name and (unset_value is None or value == unset_value)
            for unset_name, unset_value in unsets
        )
    }
    unconditionally_unset = {name for name, value in unsets if value is None}
    return {
        name: (
            "yes"
            if name in present
            else "no" if name in unconditionally_unset else "unknown"
        )
        for name in requested
    }


def command_names(args: Sequence[str]) -> int:
    if len(args) != 1:
        raise SecretToolError("usage: fm-secrets.sh names <env-file>")
    for name in unique_names(parse_env_file(args[0])):
        print(name)
    return 0


def command_has(args: Sequence[str]) -> int:
    if args and args[0] == "--service":
        if len(args) < 3:
            raise SecretToolError(
                "usage: fm-secrets.sh has --service <systemd-unit> <NAME>..."
            )
        requested = list(args[2:])
        validate_names(requested)
        presence = service_presence(args[1], requested)
    else:
        if len(args) < 2:
            raise SecretToolError(
                "usage: fm-secrets.sh has <env-file> <NAME>..."
            )
        requested = list(args[1:])
        validate_names(requested)
        present = set(unique_names(parse_env_file(args[0])))
        presence = {name: "yes" if name in present else "no" for name in requested}
    for name in requested:
        print(f"{name}={presence[name]}")
    return 0


def known_scrubbers(
    assignments: Iterable[Assignment], selected_names: Sequence[str] = ()
) -> list[tuple[bytes, bytes]]:
    scrubbers: dict[bytes, bytes] = {}
    for assignment in assignments:
        encoded = assignment.value.encode("utf-8", errors="surrogateescape")
        replacement = f"<redacted:{assignment.name}>".encode("ascii")
        if encoded and (
            assignment.name in selected_names
            or len(encoded) >= MIN_SCRUB_BYTES
            or is_secret_name(assignment.name)
        ):
            scrubbers.setdefault(encoded, replacement)
        for match in URL_PASSWORD_RE.finditer(encoded):
            password = match.group(2)
            scrubbers.setdefault(password, replacement)
            scrubbers.setdefault(unquote_to_bytes(password), replacement)
    return sorted(scrubbers.items(), key=lambda item: len(item[0]), reverse=True)


def scrub_output(data: bytes, scrubbers: Sequence[tuple[bytes, bytes]]) -> bytes:
    for value, replacement in scrubbers:
        data = data.replace(value, replacement)

    def redact_url_password(match: re.Match[bytes]) -> bytes:
        return match.group(1) + b"<redacted:URL_PASSWORD>" + match.group(3)

    return URL_PASSWORD_RE.sub(redact_url_password, data)


def scrub_stream_boundary(
    stdout: bytes, stderr: bytes, scrubbers: Sequence[tuple[bytes, bytes]]
) -> tuple[bytes, bytes]:
    stdout = scrub_output(stdout, scrubbers)
    stderr = scrub_output(stderr, scrubbers)
    for value, replacement in scrubbers:
        for split in range(1, len(value)):
            if stdout.endswith(value[:split]) and stderr.startswith(value[split:]):
                stdout = stdout[:-split] + replacement
                stderr = stderr[len(value) - split :]
                break
    return stdout, stderr


def command_run(args: Sequence[str]) -> int:
    if len(args) < 5 or args[1] != "--only":
        raise SecretToolError(
            "usage: fm-secrets.sh run <env-file> --only NAME[,NAME...] -- <command...>"
        )
    try:
        delimiter = args.index("--", 3)
    except ValueError as exc:
        raise SecretToolError("run requires -- before the command") from exc
    if delimiter != 3 or delimiter + 1 >= len(args):
        raise SecretToolError(
            "usage: fm-secrets.sh run <env-file> --only NAME[,NAME...] -- <command...>"
        )

    requested = [name.strip() for name in args[2].split(",") if name.strip()]
    validate_names(requested)
    assignments = parse_env_file(args[0])
    values = final_values(assignments)
    missing = [name for name in requested if name not in values]
    if missing:
        raise SecretToolError("settings file is missing requested names: " + ",".join(missing))

    child_env = {
        name: value
        for name, value in os.environ.items()
        if name in {"PATH", "HOME", "USER", "LOGNAME", "LANG", "TERM", "TMPDIR", "SHELL", "PWD"}
        or name.startswith("LC_")
    }
    for name in requested:
        child_env[name] = values[name]

    try:
        child = subprocess.run(
            list(args[delimiter + 1 :]),
            env=child_env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            close_fds=True,
            check=False,
        )
    except OSError as exc:
        raise SecretToolError("command could not be started") from exc

    scrubbers = known_scrubbers(
        [*assignments, *(Assignment(name, value) for name, value in child_env.items() if is_secret_name(name))],
        requested,
    )
    stdout, stderr = scrub_stream_boundary(child.stdout, child.stderr, scrubbers)
    sys.stdout.buffer.write(stdout)
    sys.stderr.buffer.write(stderr)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.flush()
    if child.returncode < 0:
        return 128 + abs(child.returncode)
    return child.returncode


def main(argv: Sequence[str]) -> int:
    if not argv:
        raise SecretToolError("run fm-secrets.sh --help for usage")
    command, args = argv[0], argv[1:]
    if command == "names":
        return command_names(args)
    if command == "has":
        return command_has(args)
    if command == "run":
        return command_run(args)
    raise SecretToolError(f"unknown subcommand: {command}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SecretToolError as error:
        print(f"fm-secrets: {error}", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        os.kill(os.getpid(), signal.SIGINT)
    except Exception:
        print("fm-secrets: operation failed safely without exposing settings", file=sys.stderr)
        sys.exit(1)

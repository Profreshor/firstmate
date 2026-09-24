#!/usr/bin/env python3
"""Even out the split ratios of one Herdr tab without touching its panes.

This helper is the wire transport for Firstmate's crew-workspace grid
(docs/herdr-backend.md "Crew workspace"). It sends only two methods: the
read-only ``layout.export`` for one exact tab, and the non-destructive
``layout.set_split_ratio``. It never sends ``layout.apply``, which recreates
every pane (verified against Herdr 0.9.1, protocol 22, and would kill the
agents running in them).

Each split gets the ratio that gives every pane an equal share along that
split's direction: a pane counts 1, a split in the same direction sums its
children, and a split in the other direction takes the larger child. A tree
of right splits holding down splits therefore becomes an even grid.

Wire protocol verified against Herdr 0.9.1, protocol 22:

  request:  {"id":ID,"method":"layout.export","params":{"tab_id":T}}\\n
  response: {"id":ID,"result":{"type":"layout_export","layout":
             {"tab_id":T,"root":NODE,...}}}\\n
  request:  {"id":ID,"method":"layout.set_split_ratio",
             "params":{"tab_id":T,"path":[bool...],"ratio":R}}\\n
  response: {"id":ID,"result":{"type":"layout_split_ratio_set","layout":{...}}}\\n

A path step of false selects a split's first child and true its second.

Usage: herdr-crew-equalize.py <socket_path> <tab_id>

Exit status:
  0  the tab's final layout has the same panes and the even ratios;
  2  arguments or socket connection were invalid;
  3  a request could not be sent or its response could not be read;
  4  a response was malformed, mismatched, reported an error, or the final
     layout changed a pane or kept an uneven ratio.
"""

import json
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
REQUEST_ID = "fm-crew-equalize"
TOLERANCE = 0.001


class Failure(Exception):
    def __init__(self, status):
        super().__init__(status)
        self.status = status


def _read_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def _call(socket_path, method, params, result_type, tab_id):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        raise Failure(2)
    try:
        request = {"id": REQUEST_ID, "method": method, "params": params}
        try:
            sock.sendall(
                (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
            )
        except OSError:
            raise Failure(3)
        line = _read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    finally:
        sock.close()
    if line is None:
        raise Failure(3)
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        raise Failure(4)
    result = response.get("result") if isinstance(response, dict) else None
    layout = result.get("layout") if isinstance(result, dict) else None
    if (
        response.get("id") != REQUEST_ID
        or response.get("error") is not None
        or result.get("type") != result_type
        or not isinstance(layout, dict)
        or layout.get("tab_id") != tab_id
        or not isinstance(layout.get("root"), dict)
    ):
        raise Failure(4)
    return layout["root"]


def _count(node, direction):
    kind = node.get("type")
    if kind == "pane":
        return 1
    if kind != "split":
        raise Failure(4)
    first, second = node.get("first"), node.get("second")
    if not isinstance(first, dict) or not isinstance(second, dict):
        raise Failure(4)
    if node.get("direction") == direction:
        return _count(first, direction) + _count(second, direction)
    return max(_count(first, direction), _count(second, direction))


def _targets(node, path, out):
    """Collect (path, current ratio, even ratio) for every split under node."""
    if node.get("type") != "split":
        return
    direction = node.get("direction")
    if direction not in ("right", "down"):
        raise Failure(4)
    first = _count(node["first"], direction)
    second = _count(node["second"], direction)
    ratio = node.get("ratio")
    if not isinstance(ratio, (int, float)):
        raise Failure(4)
    out.append((path, float(ratio), first / (first + second)))
    _targets(node["first"], path + [False], out)
    _targets(node["second"], path + [True], out)


def _panes(node):
    if node.get("type") == "pane":
        return [node.get("pane_id")]
    return _panes(node["first"]) + _panes(node["second"])


def main(argv):
    if len(argv) != 3:
        return 2
    socket_path, tab_id = argv[1:]
    if not socket_path.startswith("/") or not tab_id:
        return 2
    if any(char in tab_id for char in "\t\r\n"):
        return 2
    try:
        root = _call(socket_path, "layout.export", {"tab_id": tab_id}, "layout_export", tab_id)
        before = _panes(root)
        targets = []
        _targets(root, [], targets)
        for path, current, even in targets:
            if abs(current - even) <= TOLERANCE:
                continue
            _call(
                socket_path,
                "layout.set_split_ratio",
                {"tab_id": tab_id, "path": path, "ratio": even},
                "layout_split_ratio_set",
                tab_id,
            )
        root = _call(socket_path, "layout.export", {"tab_id": tab_id}, "layout_export", tab_id)
        if _panes(root) != before:
            return 4
        final = []
        _targets(root, [], final)
        if any(abs(current - even) > TOLERANCE for _, current, even in final):
            return 4
    except Failure as failure:
        return failure.status
    except (KeyError, TypeError, AttributeError, RecursionError):
        return 4
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)

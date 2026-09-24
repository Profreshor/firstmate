#!/usr/bin/env python3
"""Stateful fake Herdr for the portable crew-workspace suite.

It models what the crew layout depends on, using the shapes recorded against
the real binary (Herdr 0.7.4 and 0.9.1): workspaces holding tabs, each tab a
binary split tree of panes; `pane split` replaces the target leaf with a split
whose first child keeps the target; `pane close` collapses the leaf into its
sibling, removes an emptied tab, and removes an emptied workspace; `pane
layout` reports every pane's rectangle in a fixed tab area.

Usage:
  herdr-crew-fake.py cli <herdr arguments...>   (behaves as the herdr CLI)
  herdr-crew-fake.py serve <socket-path>        (serves layout.export and
                                                 layout.set_split_ratio)

State lives in $FM_FAKE_HERDR_STATE; the fake socket path the CLI reports is
$FM_FAKE_HERDR_SOCKET; the tab area is $FM_FAKE_HERDR_AREA (WIDTHxHEIGHT,
default 120x40).
"""

import fcntl
import json
import os
import socket
import sys


def area():
    raw = os.environ.get("FM_FAKE_HERDR_AREA", "120x40")
    width, height = raw.split("x")
    return int(width), int(height)


class State:
    def __init__(self):
        self.path = os.environ["FM_FAKE_HERDR_STATE"]
        self.lock = open(self.path + ".lock", "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            with open(self.path) as handle:
                self.data = json.load(handle)
        except (OSError, ValueError):
            self.data = {"next": 1, "workspaces": [], "tabs": {}, "labels": {}, "agents": {}}

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as handle:
            json.dump(self.data, handle)
        os.replace(tmp, self.path)

    def fresh(self, prefix):
        number = self.data["next"]
        self.data["next"] += 1
        return f"{prefix}{number}"


def leaves(node):
    if node["type"] == "pane":
        return [node["pane_id"]]
    return leaves(node["first"]) + leaves(node["second"])


def rects(node, x, y, width, height, out):
    if node["type"] == "pane":
        out.append({"pane_id": node["pane_id"], "rect": {"x": x, "y": y, "width": width, "height": height}})
        return
    if node["direction"] == "right":
        first = int(round(width * node["ratio"]))
        rects(node["first"], x, y, first, height, out)
        rects(node["second"], x + first, y, width - first, height, out)
    else:
        first = int(round(height * node["ratio"]))
        rects(node["first"], x, y, width, first, out)
        rects(node["second"], x, y + first, width, height - first, out)


def replace_leaf(node, pane_id, new):
    if node["type"] == "pane":
        return new if node["pane_id"] == pane_id else node
    node["first"] = replace_leaf(node["first"], pane_id, new)
    node["second"] = replace_leaf(node["second"], pane_id, new)
    return node


def remove_leaf(node, pane_id):
    """Return the tree without pane_id, or None when it was the only leaf."""
    if node["type"] == "pane":
        return None if node["pane_id"] == pane_id else node
    first = remove_leaf(node["first"], pane_id)
    second = remove_leaf(node["second"], pane_id)
    if first is None:
        return second
    if second is None:
        return first
    node["first"], node["second"] = first, second
    return node


def node_at(node, path):
    for step in path:
        if node["type"] != "split":
            return None
        node = node["second"] if step else node["first"]
    return node


def ok(result):
    print(json.dumps({"id": "cli", "result": result}))
    return 0


def err(code):
    print(json.dumps({"id": "cli", "error": {"code": code, "message": code}}))
    return 1


def option(args, name):
    if name in args:
        index = args.index(name)
        if index + 1 < len(args):
            return args[index + 1]
    return None


def workspace_view(state, workspace):
    return {
        "workspace_id": workspace["workspace_id"],
        "label": workspace["label"],
        "focused": workspace["focused"],
        "active_tab_id": workspace["active_tab_id"],
    }


def workspace_of(state, workspace_id):
    for workspace in state.data["workspaces"]:
        if workspace["workspace_id"] == workspace_id:
            return workspace
    return None


def tab_view(state, tab_id):
    tab = state.data["tabs"][tab_id]
    workspace = workspace_of(state, tab["workspace_id"])
    return {
        "tab_id": tab_id,
        "workspace_id": tab["workspace_id"],
        "label": tab["label"],
        "focused": bool(workspace["focused"] and workspace["active_tab_id"] == tab_id),
        "pane_count": len(leaves(tab["root"])),
    }


def pane_index(state):
    index = {}
    for tab_id, tab in state.data["tabs"].items():
        for pane_id in leaves(tab["root"]):
            index[pane_id] = tab_id
    return index


def pane_view(state, pane_id, tab_id):
    view = {"pane_id": pane_id, "tab_id": tab_id, "workspace_id": state.data["tabs"][tab_id]["workspace_id"]}
    if pane_id in state.data["labels"]:
        view["label"] = state.data["labels"][pane_id]
    return view


def new_tab(state, workspace_id, label):
    tab_id = state.fresh(f"{workspace_id}:t")
    pane_id = state.fresh(f"{workspace_id}:p")
    workspace = workspace_of(state, workspace_id)
    state.data["tabs"][tab_id] = {
        "workspace_id": workspace_id,
        "label": label or str(sum(1 for t in state.data["tabs"].values() if t["workspace_id"] == workspace_id) + 1),
        "root": {"type": "pane", "pane_id": pane_id},
    }
    if not workspace["active_tab_id"]:
        workspace["active_tab_id"] = tab_id
    return tab_id, pane_id


def close_pane(state, pane_id):
    index = pane_index(state)
    tab_id = index[pane_id]
    tab = state.data["tabs"][tab_id]
    tab["root"] = remove_leaf(tab["root"], pane_id)
    state.data["labels"].pop(pane_id, None)
    if tab["root"] is not None:
        return
    workspace = workspace_of(state, tab["workspace_id"])
    del state.data["tabs"][tab_id]
    remaining = [t for t, v in state.data["tabs"].items() if v["workspace_id"] == workspace["workspace_id"]]
    if workspace["active_tab_id"] == tab_id:
        workspace["active_tab_id"] = remaining[0] if remaining else ""
    if not remaining:
        state.data["workspaces"].remove(workspace)
        if workspace["focused"] and state.data["workspaces"]:
            state.data["workspaces"][0]["focused"] = True


def cli(args):
    if len(args) >= 2 and args[-2] == "--session":
        session = args[-1]
        args = args[:-2]
    else:
        session = os.environ.get("HERDR_SESSION", "default")
    if args == ["--version"]:
        print("herdr 0.9.1")
        return 0
    command = " ".join(args[:2])
    if command == "status --json":
        return print(json.dumps({
            "client": {"version": "0.9.1", "protocol": 22},
            "server": {"running": True, "version": "0.9.1", "protocol": 22, "compatible": True},
        })) or 0
    if command == "api schema":
        methods = ["layout.export", "layout.set_split_ratio", "pane.split", "pane.layout"]
        if os.environ.get("FM_FAKE_HERDR_NO_LAYOUT_API"):
            methods = ["pane.split", "pane.layout"]
        return print(json.dumps({"schemas": {"request": {"oneOf": [
            {"properties": {"method": {"const": method}}} for method in methods
        ], "$defs": {}}}})) or 0
    if command == "session list":
        return print(json.dumps({"sessions": [
            {"name": session, "running": True, "socket_path": os.environ["FM_FAKE_HERDR_SOCKET"]}
        ]})) or 0
    if command == "terminal title":
        return ok({"type": "ok", "reason": "no_foreground_client"})

    state = State()
    try:
        return dispatch(state, command, args)
    finally:
        state.lock.close()


def dispatch(state, command, args):
    rest = args[2:]
    if command == "workspace list":
        return ok({"type": "workspace_list", "workspaces": [workspace_view(state, w) for w in state.data["workspaces"]]})
    if command == "workspace create":
        workspace_id = state.fresh("w")
        first = not state.data["workspaces"]
        workspace = {"workspace_id": workspace_id, "label": option(rest, "--label") or "", "focused": first, "active_tab_id": ""}
        state.data["workspaces"].append(workspace)
        tab_id, pane_id = new_tab(state, workspace_id, "1")
        state.save()
        return ok({"type": "workspace_created", "workspace": workspace_view(state, workspace),
                   "tab": tab_view(state, tab_id), "root_pane": pane_view(state, pane_id, tab_id)})
    if command == "tab list":
        workspace_id = option(rest, "--workspace")
        return ok({"type": "tab_list", "tabs": [
            tab_view(state, t) for t, v in state.data["tabs"].items() if v["workspace_id"] == workspace_id
        ]})
    if command == "tab get":
        if not rest or rest[0] not in state.data["tabs"]:
            return err("tab_not_found")
        return ok({"type": "tab_info", "tab": tab_view(state, rest[0])})
    if command == "tab create":
        workspace_id = option(rest, "--workspace")
        if workspace_of(state, workspace_id) is None:
            return err("workspace_not_found")
        tab_id, pane_id = new_tab(state, workspace_id, option(rest, "--label"))
        state.save()
        return ok({"type": "tab_created", "tab": tab_view(state, tab_id), "root_pane": pane_view(state, pane_id, tab_id)})
    if command == "tab focus":
        tab = state.data["tabs"].get(rest[0] if rest else "")
        if tab is None:
            return err("tab_not_found")
        for workspace in state.data["workspaces"]:
            workspace["focused"] = workspace["workspace_id"] == tab["workspace_id"]
        workspace_of(state, tab["workspace_id"])["active_tab_id"] = rest[0]
        state.save()
        return ok({"type": "ok"})
    index = pane_index(state)
    if command == "pane list":
        workspace_id = option(rest, "--workspace")
        return ok({"type": "pane_list", "panes": [
            pane_view(state, p, t) for p, t in index.items()
            if workspace_id is None or state.data["tabs"][t]["workspace_id"] == workspace_id
        ]})
    if command == "pane get":
        if not rest or rest[0] not in index:
            return err("pane_not_found")
        return ok({"type": "pane_info", "pane": pane_view(state, rest[0], index[rest[0]])})
    if command == "pane split":
        target = rest[0] if rest and not rest[0].startswith("--") else option(rest, "--pane")
        if target not in index:
            return err("pane_not_found")
        tab_id = index[target]
        pane_id = state.fresh(f"{state.data['tabs'][tab_id]['workspace_id']}:p")
        ratio = float(option(rest, "--ratio") or 0.5)
        tab = state.data["tabs"][tab_id]
        tab["root"] = replace_leaf(tab["root"], target, {
            "type": "split", "direction": option(rest, "--direction") or "right", "ratio": ratio,
            "first": {"type": "pane", "pane_id": target}, "second": {"type": "pane", "pane_id": pane_id},
        })
        state.save()
        return ok({"type": "pane_info", "pane": pane_view(state, pane_id, tab_id)})
    if command == "pane layout":
        target = option(rest, "--pane")
        if target not in index:
            return err("pane_not_found")
        tab_id = index[target]
        width, height = area()
        panes = []
        rects(state.data["tabs"][tab_id]["root"], 0, 0, width, height, panes)
        return ok({"type": "pane_layout", "layout": {
            "area": {"x": 0, "y": 0, "width": width, "height": height},
            "panes": panes, "tab_id": tab_id, "workspace_id": state.data["tabs"][tab_id]["workspace_id"],
        }})
    if command == "pane rename":
        if not rest or rest[0] not in index:
            return err("pane_not_found")
        state.data["labels"][rest[0]] = " ".join(rest[1:])
        state.save()
        return ok({"type": "pane_info", "pane": pane_view(state, rest[0], index[rest[0]])})
    if command == "pane close":
        if not rest or rest[0] not in index:
            return err("pane_not_found")
        close_pane(state, rest[0])
        state.save()
        return ok({"type": "ok"})
    if command == "agent get":
        status = state.data["agents"].get(rest[0] if rest else "")
        if status is None:
            return err("agent_not_found")
        return ok({"type": "agent_info", "agent": {"agent": "claude", "agent_status": status}})
    return err("unsupported_by_fake")


def serve(socket_path):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(8)
    while True:
        connection, _ = server.accept()
        with connection:
            buffer = b""
            while b"\n" not in buffer:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                buffer += chunk
            try:
                request = json.loads(buffer.split(b"\n", 1)[0])
            except ValueError:
                continue
            response = handle(request)
            connection.sendall((json.dumps(response) + "\n").encode())


def handle(request):
    state = State()
    try:
        method, params = request.get("method"), request.get("params") or {}
        tab_id = params.get("tab_id")
        tab = state.data["tabs"].get(tab_id)
        if tab is None:
            return {"id": request.get("id"), "error": {"code": "layout_not_found"}}
        if method == "layout.set_split_ratio":
            node = node_at(tab["root"], params.get("path", []))
            if node is None or node["type"] != "split":
                return {"id": request.get("id"), "error": {"code": "layout_not_found"}}
            node["ratio"] = params["ratio"]
            state.save()
            kind = "layout_split_ratio_set"
        elif method == "layout.export":
            kind = "layout_export"
        else:
            return {"id": request.get("id"), "error": {"code": "method_not_allowed"}}
        return {"id": request.get("id"), "result": {"type": kind, "layout": {
            "workspace_id": tab["workspace_id"], "tab_id": tab_id, "root": tab["root"],
        }}}
    finally:
        state.lock.close()


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "serve":
        serve(sys.argv[2])
    elif len(sys.argv) >= 2 and sys.argv[1] == "cli":
        sys.exit(cli(sys.argv[2:]))
    else:
        sys.exit(2)

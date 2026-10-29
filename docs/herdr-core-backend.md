# herdr-core runtime backend

herdr-core is an experimental runtime backend for the herdr-core platform, whose CLI is `hc`.
It is a different product from Herdr ([`herdr-backend.md`](herdr-backend.md)): it has no workspaces, tabs, or panes, and every program runs in a flat, persistent terminal addressed as `t1`, `t2`, and so on inside one per-user core.
Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick herdr-core when Firstmate itself runs in a herdr-core terminal and you want its workers there too.

Prerequisites:

- herdr-core 0.1.13 or newer, with `hc` on `PATH`; `hc update` upgrades it.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select herdr-core with local `config/backend` containing `herdr-core`, `FM_BACKEND=herdr-core` for one launch, or an explicit request to Firstmate.
It can also be runtime auto-detected when Firstmate runs inside an hc terminal; see [Runtime detection](#runtime-detection).
A spawn stops with an actionable message when `hc` is missing or older than 0.1.13, or `jq` is missing.

Verify setup by spawning a small task and confirming metadata contains `backend=herdr-core`, `herdr_core_session=`, and `herdr_core_terminal=`, and that `hc ls` lists the new terminal.

## Runtime detection

herdr-core puts `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET` into every terminal its core runs, and `HC_TERMINAL_ID` is the detection marker.
Detection checks tmux first, so a tmux session started inside an hc terminal stays on tmux.

hc terminals inherit the core's environment, not the environment of the `hc` command that created them.
A core that was itself started from inside a Herdr pane therefore carries `HERDR_ENV=1` into every hc terminal, and Herdr started inside an hc terminal carries both markers too.
When both `HC_TERMINAL_ID` and `HERDR_ENV=1` are present, the first `herdr` or `herdr-core` process in Firstmate's own process ancestry is the innermost layer and wins.
When the ancestry reaches neither, Herdr keeps its established precedence.

An auto-detected herdr-core prints a stderr notice naming `config/backend` and `--backend tmux`, because the backend is experimental.

## How tasks run

Each task is one hc terminal running the user's login shell, started in the project directory and then moved into the task worktree, exactly like a tmux window.
The terminal is created with `--no-parent` and `--no-notify`, so it does not end when the terminal that spawned it ends and hc types no notes into Firstmate's own terminal.

Ownership is proven by labels, never by address alone.
Every task terminal carries `fm_home=<home label>` and `fm_task=<task id>`, where the home label is the readable home prefix plus a short hash of the resolved `FM_ROOT` path, shared with zellij and cmux.
A terminal whose labels do not name this home, and the task when the caller knows it, is never read, typed into, killed, or removed, and reads as `missing`.
`hc ls --label fm_home=<home label>` lists only this home's task terminals.

The recorded target is `<hc session>:<address>`, for example `default:t7`.
hc picks its core from `HC_SESSION`, defaulting to `default`, and addresses are per core, so every call is pinned to the recorded session.
A new task lands in the session the spawning Firstmate addresses.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Interrupt, exit, and relaunch run through `bin/fm-control.sh`, because herdr-core has a recovery-grade agent-state classifier: it classifies the foreground process hc reports through the same shared classifier tmux and Herdr use, reads a finished terminal or a shell in the foreground as agent-free, and reads `missing` only when the recorded session's core reports this home's terminal absent.
A relaunch adopts an agent-free terminal, or creates one fresh terminal in the recorded session and worktree when the old one is proven gone.
Busy state comes from hc's own status, which the program reports itself; `working` counts as busy only while a harness process is in the foreground.

## Limits

- herdr-core has no way to type text without submitting it: `hc send` pastes and presses Enter in one call, and `hc keys` takes only named keys.
  A submit is therefore one `hc send` followed by Enter-only retries while the composer still holds the text, and the spawn sends its launch line the same way.
- Composer reads are plain text with no cursor or identity facts, so the shared composer classifier runs in its plain-text mode, as it does for cmux.
- `--secondmate` spawns are refused until secondmate launch semantics are designed for this backend.
- There is no native event push, so the watcher uses its ordinary poll loop.
- hc starts a session's core on first use, so a passive liveness read of a recorded session whose core is stopped starts an empty core.
  A core that was stopped took its non-kept terminals with it, which is why a `missing` answer from that session is treated as proof the terminal is gone.
- The away-mode sub-supervisor still injects only into tmux or Herdr supervisor panes.

[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr-core) owns the live evidence behind these facts, and `tests/fm-backend-herdr-core.test.sh` pins the adapter against a fake `hc`.

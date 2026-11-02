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

## Herdr app visibility

The Herdr app shows a core terminal only when it carries both a `herdr.space` and a `herdr.tab` label, and terminals that share both ids appear together as split panes in one tab.
When Firstmate's own terminal carries `herdr.space`, meaning Firstmate itself was started from the app, every task terminal this home creates in that same core gets `herdr.space=sp<hash>crew` and `herdr.tab=tb<hash>crew`, where `<hash>` is the hash part of the home label.
All of one home's workers therefore share a dedicated crew space, separate from Firstmate's own, with one tab of split panes.
An id the app does not know yet creates that space or tab, so the captain can name the crew space once in the app and the name sticks across later workers.
When Firstmate's terminal has no `herdr.space`, or the task lands in a different core, workers get no `herdr.*` labels.
These labels are set only when the task terminal is created; Firstmate never changes `herdr.*` labels on any terminal, including its own.

The recorded target is `<hc session>:<address>`, for example `default:t7`.
hc picks its core from `HC_SESSION`, defaulting to `default`, and addresses are per core, so every call is pinned to the recorded session.
A new task lands in the session the spawning Firstmate addresses.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Interrupt, exit, and relaunch run through `bin/fm-control.sh`, because herdr-core has a recovery-grade agent-state classifier: it classifies the foreground process hc reports through the same shared classifier tmux and Herdr use, reads a finished terminal or an interactive shell in the foreground as agent-free, and reads `missing` only when the recorded session's core reports this home's terminal absent.
A ship's launch runs the harness under an `sh -c` wrapper, which hc keeps reporting as the foreground for the agent's whole life, and a node-bundled harness can show as plain `node`.
Such a foreground counts as the agent when the program's self-reported hc status names a harness, and a wrapper that has reported no status yet reads as ambiguous.
hc clears that status when the program exits.
A relaunch adopts a live terminal whose shell is in the foreground.
A finished terminal is removed and replaced in its recorded session and worktree, while an absent terminal is replaced once its absence is proven.
Busy state comes from hc's own status, which the program reports itself; `working` counts as busy only while the foreground classifies as the agent.

## Limits

- herdr-core has no way to type text without submitting it: `hc send` pastes and presses Enter in one call, and `hc keys` takes only named keys.
  A submit is therefore one `hc send` followed by Enter-only retries while the composer still holds the text, and the spawn sends its launch line the same way.
- hc can wrap text sent from inside an hc terminal in an `<hc from="...">` tag, so a slash command such as Claude Code's `/exit` arrives as chat and `bin/fm-control.sh exit` cannot stop the worker.
  hc's help names `notes = false` in `~/.config/herdr-core/config.toml` as the setting that disables the tag.
- Composer reads are plain text with no cursor or identity facts, so the shared composer classifier runs in its plain-text mode, as it does for cmux.
- `--secondmate` spawns are refused until secondmate launch semantics are designed for this backend.
- There is no native event push, so the watcher uses its ordinary poll loop.
- hc starts a session's core on first use, so a passive liveness read of a recorded session whose core is stopped starts an empty core.
  A core that was stopped took its non-kept terminals with it, which is why a `missing` answer from that session is treated as proof the terminal is gone.
- The away-mode sub-supervisor still injects only into tmux or Herdr supervisor panes.

[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr-core) owns the live evidence behind these facts, and `tests/fm-backend-herdr-core.test.sh` pins the adapter against a fake `hc`.

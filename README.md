# Helios

One window, many research contexts. Each tab pairs a **local terminal** (usually Claude Code in a project directory) on the left with an **SSH session** to a cluster or VM on the right, replacing the multiple-desktops-with-Termius setup.

## Build & run

```sh
swift run                         # dev
./scripts/build-app.sh            # -> build/Helios.app
./scripts/build-app.sh --install  # also copies to ~/Applications
```

Requires macOS 14+ and the Xcode toolchain. Terminal emulation is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), pinned to 1.20.0 (1.99.x doesn't compile with Swift 6.2).

## Contexts

A context stores: name, local directory, startup command (default `claude`), SSH host (alias from `~/.ssh/config` or `user@host`), and an optional remote directory. Saved to `~/Library/Application Support/Helios/contexts.json`.

Contexts are listed in the left sidebar; the strip at the top of each one shows its local dir and SSH status. Terminals start the first time a context is opened and keep running while you switch.

| Shortcut | Action |
|---|---|
| ⌘T | New context |
| ⇧⌘E | Edit current context |
| ⇧⌘R | Restart current context's terminals |
| ⌘1…⌘9 | Jump to context |
| ⇧⌘[ / ⇧⌘] | Previous / next context |
| ⌥⌘T | New SSH sub-tab |
| ⌘I | Toggle drawer |
| ⌥⌘1…⌥⌘4 | Drawer: Jobs / Git / Notes / Files |

## Theme

Colors and font come from your Ghostty config (`~/.config/ghostty/config`, plus its `theme =` file): `background`, `foreground`, `palette` 0–15, `cursor-color`, `selection-background`, `font-family`, `font-size`. The sidebar, header and borders are derived from the same colors. Restart Helios after changing the Ghostty config.

## SSH, tmux, and reconnect

The right pane runs `ssh -t <host> tmux new-session -A -s helios-<id> [-c <remote dir>]`, so the remote shell lives in a tmux session on the server and survives disconnects, laptop sleep, and app restarts.

- **Auto-reconnect:** if ssh exits with a connection error (255) or is killed, Helios retries with backoff (1, 2, 4 … 30s, up to 8 attempts) and reattaches to the same tmux session. A clean exit (you exited or detached tmux) does not reconnect; press **Reconnect**.
- **2FA:** connections use `ControlMaster=auto` / `ControlPersist=4h` with a socket at `~/.ssh/helios-cm-%C`, so one 2FA approval is shared by every pane to that host. After a real network drop, the 2FA prompt appears in the pane.
- If tmux isn't on the remote `PATH`, it falls back to a plain login shell (no persistence).
- Clusters with round-robin login nodes: point the host at a specific node (e.g. `login1`) so you reattach to the node holding your tmux session.

The **local** pane is a normal shell; quitting Helios ends local processes (e.g. a running `claude`).

## Panels

The info strip at the top of a context shows chips for the local dir, git branch (±changes, ↑↓ vs upstream), SSH status, and SLURM jobs (running / pending). Clicking a chip opens the drawer under the terminals:

- **Jobs** — `squeue -u $USER`, refreshed every 30s while the context is on screen. Hover a job for `gpu` (`srun --jobid --overlap nvidia-smi`), `info` (`scontrol show job`), `cancel` (`scancel`, confirmed). Toolbar: login-node GPU and disk quota (`diskusage_report` on Alliance clusters, else `quota`/`df`). Hidden on hosts without SLURM.
- **Git** — changed files and recent commits for the local dir, refreshed every 10s.
- **Notes** — per-context scratchpad, saved with the context.
- **Files** — browse the remote dir; double-click folders, `cd here` sends `cd` to the SSH tab, download selection into the local dir, upload via picker or drag-and-drop from Finder (rsync).

Background remote commands only run over an already-authenticated shared connection (checked locally with `ssh -O check`, then `BatchMode=yes`), so they never open new logins, prompt for 2FA, or risk failed-login lockouts. Until the SSH pane is authenticated, panels show "Not connected".

**SSH sub-tabs** sit above the right pane; each is its own tmux session (`helios-<id>-<tab>`) over the shared connection. Closing one kills its tmux session; the first tab can't be closed.

The local/remote split and the drawer height are draggable and remembered.

## Roadmap

All originally planned features are in. Ideas: run the local pane inside tmux too (so `claude` survives app restarts); activity badges on background contexts.

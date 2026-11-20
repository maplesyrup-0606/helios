# Helios

One window, many research contexts. Each context pairs a **local terminal** (usually [Claude Code](https://claude.com/claude-code) in a project directory) on the left with an **SSH session** to a cluster or VM on the right, with git, SLURM jobs, remote files and notes one click away. It replaces juggling multiple desktops, terminal windows and an SSH client.

- Terminals keep running while you switch contexts, and survive quitting Helios (local and remote panes live in tmux).
- SSH panes auto-reconnect and share one authenticated connection per host, so 2FA is approved once.
- An info strip and drawer show git status, SLURM jobs (with tqdm progress), remote files and per-context notes.
- Background contexts get a badge when Claude finishes or a terminal rings the bell.

## Installation

### Requirements

- macOS 14 (Sonoma) or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`), for Swift
- [tmux](https://github.com/tmux/tmux) locally (`brew install tmux`), recommended so local panes survive restarts
- tmux on remote hosts, recommended so SSH sessions survive disconnects

### Build and install

```sh
git clone https://github.com/maplesyrup-0606/helios.git
cd helios
./scripts/build-app.sh --install
```

This builds a release `Helios.app` and copies it to `/Applications`, so it shows up in Spotlight, Launchpad and the Dock. The app is ad-hoc signed on your machine, so it opens without Gatekeeper warnings.

### Updating

```sh
git pull
./scripts/build-app.sh --install
./scripts/relaunch.sh    # quits Helios, waits for it to exit, reopens the installed copy
```

Running terminals aren't lost: Helios reattaches to their tmux sessions on launch.

### Other build options

```sh
swift run                      # run a debug build straight from the checkout
./scripts/build-app.sh         # build build.noindex/Helios.app without installing
swift test                     # run the tests
```

## Quick start

1. Open Helios and press **⌘T** to create a context.
2. Fill in:
   - **Name**: anything, e.g. `geodesic`.
   - **Local directory**: the project folder the left pane opens in.
   - **Startup command**: what the left pane runs, `claude` by default.
   - **SSH host**: an alias from `~/.ssh/config` or `user@host`. Leave empty for a local-only context.
   - **Remote directory** (optional): where the remote shell starts.
3. The left pane starts Claude Code in your project, and the right pane connects over SSH. Approve 2FA in the right pane if your host asks.
4. Add more contexts with ⌘T and switch between them from the sidebar or with ⌘1…⌘9.

Contexts are saved to `~/Library/Application Support/Helios/contexts.json`.

## Usage

### Layout

- **Sidebar**: your contexts. A badge means something happened there while you were away (see [Attention](#attention)).
- **Info strip** (top): chips for git branch, SSH status and SLURM jobs, plus buttons for refresh, remote files, notes, the drawer and editing the context.
- **Panes**: local on the left, SSH on the right. Drag the divider to resize; the split is remembered.
- **Sub-tabs** above each pane: ⇧⌘T opens another shell in the focused pane. Local sub-tabs are plain shells in the project directory; SSH sub-tabs are extra tmux sessions over the same connection.
- **Drawer** (⌘I): jobs, git, notes and files under the terminals. Its height is draggable and remembered.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘T | New context |
| ⇧⌘E | Edit current context |
| ⌘1…⌘9 | Jump to context |
| ⇧⌘[ / ⇧⌘] | Previous / next context |
| ⌘[ / ⌘] | Focus local / SSH pane |
| ⇧⌘T | New sub-tab in the focused pane |
| ⇧⌘← / ⇧⌘→ | Previous / next sub-tab in the focused pane |
| ⌘W | Close the focused pane's sub-tab (asks first; a pane's first tab can't be closed) |
| ⌘I | Toggle drawer |
| ⌘K | Command palette |
| ⇧⌘R | Restart all of the current context's terminals (tmux sessions are reattached, nothing is lost) |

### Selecting, copying and editing text

- **Click and drag** selects text; double-click selects a word, triple-click a line. The selection stays put while output streams in.
- **⌘C** copies the selection. A command that Claude wrapped across several indented rows is copied as the original single line, so it pastes cleanly into a shell.
- **⌘V** pastes as a bracketed paste, so multi-line text isn't run line by line.
- **Scroll wheel** scrolls tmux history.
- In the shell or Claude's prompt: **⌥← / ⌥→** jump by word, **⌥⌫** deletes a word, **⌘← / ⌘→** jump to line start/end, **⌘⌫** deletes to line start.

### SSH sessions

The right pane runs `ssh -t <host> tmux new-session -A -s helios-<id> [-c <remote dir>]`, so the remote shell lives in tmux on the server and survives disconnects, laptop sleep and app restarts.

- **Refresh:** if an SSH pane freezes or gets stuck, click the **↻** button in the info strip (or "Reconnect SSH" in the ⌘K palette). It kills that pane's ssh and reattaches to the same tmux session.
- **Auto-reconnect:** if ssh drops with a connection error, Helios retries with backoff (1, 2, 4 … 30s, up to 8 attempts) and reattaches. The SSH chip shows the countdown with a **now** button. A clean exit (you exited or detached tmux) doesn't reconnect; press **reconnect** on the chip.
- **2FA once per host:** connections use `ControlMaster=auto` / `ControlPersist=4h` with a socket at `~/.ssh/helios-cm-%C`, so every pane and panel to that host shares one login. After a real network drop, the 2FA prompt appears in the pane.
- If tmux isn't on the remote `PATH`, Helios falls back to a plain login shell (no persistence).
- **Clusters with round-robin login nodes:** point the host at a specific node (e.g. `login1`) so you reattach to the node holding your tmux session.

### Local pane and Claude Code

The local pane runs in a local tmux session (`helios-local-<id>`) when tmux is installed, so a running `claude` survives quitting or updating Helios.

- The startup command runs only when a new session is created (first open, after a reboot, or after the shell exits); otherwise Helios reattaches.
- With **Resume last Claude conversation** on (the default), a `claude` startup command becomes `claude --continue` when that directory has past conversations.
- Changing the local directory or deleting the context kills its session. Editing the startup command doesn't interrupt a running one.

### Drawer panels

Click a chip in the info strip to open its panel:

- **Jobs**: `squeue -u $USER`, refreshed every 30s while the context is on screen. Hover a job for `gpu` (`nvidia-smi` inside the job), `info` (`scontrol show job`) or `cancel` (`scancel`, confirmed). The toolbar shows login-node GPU and disk quota. Running jobs show **tqdm progress** (bar, %, counts, ETA, rate) parsed from their output files. Hidden on hosts without SLURM.
- **Git**: changed files and recent commits for the local directory, refreshed every 10s.
- **Notes**: a per-context scratchpad, saved with the context.
- **Files**: browse the remote directory. Double-click folders; `cd here` sends `cd` to the SSH pane; download the selection into the local directory; upload with the picker or by dragging from Finder (rsync).

Panels only run remote commands over an already-authenticated shared connection (`BatchMode=yes`), so they never open new logins, trigger 2FA prompts or risk failed-login lockouts. Until the SSH pane has logged in, they show "Not connected".

### Attention

A background context gets a pulsing sidebar badge (and the Dock icon a count) when:

- a terminal rings the **bell** (accent badge), or
- the local pane **goes quiet** after 3s or more of continuous output, e.g. Claude finished or is waiting for input (green badge).

When Helios isn't the active app it also bounces the Dock icon and posts a notification. Badges clear when you open the context. For precise Claude signals, set Claude Code's notifications to the terminal bell (`/config` → notifications → terminal bell).

### Theme

Colors and font come from your [Ghostty](https://ghostty.org) config (`~/.config/ghostty/config` or `~/Library/Application Support/com.mitchellh.ghostty/config`, plus its `theme =` file): `background`, `foreground`, `palette` 0–15, `cursor-color`, `selection-background`, `font-family` and `font-size`. The sidebar, header and borders are derived from the same colors. Restart Helios after changing the config. Without a Ghostty config, Helios uses its built-in dark theme.

## Troubleshooting

| Problem | Fix |
|---|---|
| SSH pane frozen or garbled | Click **↻** in the info strip to reconnect that pane. |
| Every pane in a context is stuck | ⇧⌘R restarts the context's terminals and reattaches tmux. |
| Panels say "Not connected" | Log in (and approve 2FA) in the SSH pane first; panels reuse that connection. |
| Reconnected to an empty session on a cluster | Your host alias hit a different login node; pin it to one node in `~/.ssh/config`. |
| Local pane started fresh after a reboot | Expected: tmux sessions don't survive reboots, so the startup command runs again. |

## Development

A Swift Package Manager project: sources are in `Sources/Helios`, tests in `Tests/HeliosTests`. Terminal emulation is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), pinned to 1.20.0 (1.99.x doesn't compile with Swift 6.2). `scripts/make-icon.swift` renders the app icon.

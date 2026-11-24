# Pomodoro — Omarchy Shell Bar Timer

A focus/break timer widget for the [Omarchy](https://omarchy.org/) shell bar
(Quickshell), with a settings panel, a daily screen-time display, and an
optional "site-blocker reward" that unblocks distracting sites after a set
number of completed focus sessions.

## Features

- **Focus / short break / long break** phases with automatic cycling
- **Settings panel** (right-click) for every duration and behavior
- **Enforced limits** so the timer can't be set to useless values:
  - Focus session: **minimum 30 minutes**
  - Short break: **maximum 15 minutes**
  - Long break: **maximum 15 minutes**
  - Sessions to unblock: **minimum 2**
- **Daily screen-time counter** shown in the panel (from the optional
  `daily-screen-limit` service)
- **Restriction-free reward window**: every N completed focus sessions lifts
  the site-blocker DNS block for a configurable number of minutes

## Requirements

- Omarchy shell (Quickshell) with local plugin support
- Optional: `site-blocker` (included in [`site-blocker/`](site-blocker/)) installed
  at `/usr/local/bin/site-blocker` with passwordless `sudo` for `pause`/`resume`
- Optional: the `daily-screen-limit` user service (included in this guide)

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/stalss/timer-project.git
cd timer-project
```

### 2. Install the plugin

Copy the plugin files into your local Omarchy plugins directory:

```bash
mkdir -p ~/.config/omarchy/plugins/larper.pomodoro
cp manifest.json Panel.qml Pomodoro.qml WallClock.qml \
   ~/.config/omarchy/plugins/larper.pomodoro/
```

Reload the shell so it picks up the new plugin:

```bash
omarchy restart shell
```

### 3. Add the widget to the bar

Add an entry for `larper.pomodoro` to the widgets list in
`~/.config/omarchy/shell.json`, under `bar.widgets.start` (or `center` /
`end` — any of the widget sections):

```json
{
  "id": "larper.pomodoro",
  "workMinutes": 30,
  "breakMinutes": 1,
  "autoStartFocus": true,
  "sessionsBeforeLong": 2,
  "rewardSessions": 2,
  "rewardMinutes": 120,
  "longBreakMinutes": 1,
  "dailyLimitMinutes": 360
}
```

Restart the shell again. The timer should now appear in the bar.

### 4. (Optional) Set up the site-blocker reward

The widget calls:

```bash
sudo -n /usr/local/bin/site-blocker pause <rewardMinutes>
sudo -n /usr/local/bin/site-blocker resume
```

So `site-blocker` must be installed, and your user needs a sudoers rule like:

```
<your-username> ALL=(root) NOPASSWD: /usr/local/bin/site-blocker pause *, /usr/local/bin/site-blocker resume
```

(Replace `<your-username>` with your actual user name and adjust paths for
your system. Never edit sudoers with a plain text editor — use `visudo`.)

The widget reads `/var/lib/site-blocker/pause.json` to display the live
countdown of the restriction-free window. Without site-blocker, the timer and
settings panel still work; only the reward button/indicator is inactive.

### 5. (Optional) Set up the daily screen-time counter

The panel displays time used today, read from:

```
~/.local/state/omarchy/daily-screen-limit.json
```

That file is written by the `daily-screen-limit` service. To install it, copy
the included script and make it executable:

```bash
install -m 755 daily-screen-limit ~/.local/bin/daily-screen-limit
```

Then add these two user units:

**`~/.config/systemd/user/daily-screen-limit.service`**

```ini
[Unit]
Description=Daily screen-time limiter tick
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/daily-screen-limit
```

**`~/.config/systemd/user/daily-screen-limit.timer`**

```ini
[Unit]
Description=Check daily screen-time limit every minute

[Timer]
OnActiveSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=default.target
```

Enable it with:

```bash
systemctl --user daemon-reload
systemctl --user enable --now daily-screen-limit.timer
```

The limit is read from `dailyLimitMinutes` in the widget's shell.json entry
(max 360 minutes / 6 hours). The script warns 15 minutes before the limit and
terminates the desktop session when it is reached.

## Usage

| Mouse button | Action |
|---|---|
| Left click | Start / pause the timer |
| Right click | Open the settings panel |
| Middle click | Skip to the next phase (does **not** count as a completed focus session) |

In the settings panel you can change focus/break/long-break lengths,
auto-start behavior, sessions before a long break, the reward settings, and
reset today's completed-session count.

### Reward behavior

- Completed focus sessions are counted per day in
  `$XDG_STATE_HOME/omarchy/pomodoro.json` (default `~/.local/state/omarchy/pomodoro.json`).
- Every `rewardSessions`-th session (minimum 2) runs the site-blocker pause
  command, granting a restriction-free window of `rewardMinutes`.
- The panel shows the remaining time in the current window and has a button to
  restore blocking early.
- "Reset today's count" only clears progress toward the next reward — an
  already-active window keeps running until it expires or is restored.

## Configuration reference

| Setting | Default | Range / rule |
|---|---|---|
| `workMinutes` | 30 | min 30 |
| `breakMinutes` | 5 | max 15 |
| `longBreakMinutes` | 15 | max 15 |
| `sessionsBeforeLong` | 4 | min 1 |
| `autoStartBreaks` | `true` | boolean |
| `autoStartFocus` | `false` | boolean |
| `rewardSessions` | 4 | min 2 |
| `rewardMinutes` | 120 | 5–480 |
| `dailyLimitMinutes` | 180 | 5–360 |

Bounds are enforced both in the UI (slider ranges) and in code
(`Pomodoro.qml`), including when values are written directly to `shell.json`.

## Notes

- `Pomodoro.qml` uses `Quickshell.env("HOME")` (with `XDG_STATE_HOME`
  override) to find the daily screen-time state file, so it works for any
  user. The site-blocker paths (`/usr/local/bin/site-blocker`,
  `/var/lib/site-blocker/pause.json`) are system-wide and only matter if you
  use the optional reward feature.
- `larper.pomodoro` is the plugin's module ID (a namespace), not a user
  account. Leave it as-is when installing.
- After changing QML files, run `omarchy restart shell` — a plugin hot-reload
  alone may not refresh the active widget code.

# mac-shutdown

[![CI](https://github.com/borun/mac-shutdown-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/borun/mac-shutdown-skill/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An [Agent Skill](https://agentskills.io) that shuts your Mac down gracefully once your coding agent has finished its work, or at a time you choose. Built for [Claude Code](https://claude.com/claude-code), and it works in any agent that can run a shell command.

Tell your agent "finish the tests, push if they pass, then shut down my Mac", and it does the work, schedules the shutdown, and tells you how to cancel it. The next morning, ask "did my Mac shut down properly?" and it reads the log back to you.

## What it does

When the time comes, a small background script works down this list until the Mac is off:

1. Shows a 60-second warning with **Cancel shutdown** and **Shut down now** buttons. If nobody answers, it carries on.
2. Stops Docker Desktop gracefully, and OrbStack or Colima if they're running. Each container gets its own stop timeout and keeps its restart policy.
3. Saves drafts in TextEdit, Pages, Numbers and Keynote. Documents with a file are saved in place; never-saved drafts go to `~/Documents/Saved before shutdown/<date time>/`. Every path is logged.
4. Asks every other app to quit.
5. Closes terminals, after logging what was running in them, with passwords and tokens hidden.
6. Asks macOS to shut down.
7. If an app refuses (the app your agent runs in usually does), it ends that app and asks again.
8. If the Mac still won't shut down, it puts it to sleep instead.

If the Mac sleeps during these steps, say because you closed the lid, the run stops when the Mac wakes rather than closing apps under you.

Every step is logged in `~/Library/Logs/mac-shutdown/`.

## Why it's a skill and not a one-liner

`osascript -e 'tell application "System Events" to shut down'` looks like enough, but it fails when an agent runs it:

- **The app the agent runs in refuses to quit,** and one refusing app cancels the whole shutdown. The Claude desktop app does this. A session also can't quit its own app. So the shutdown runs from a separate process that outlives the app and can end it. The script finds that app by itself, whether it's Claude, VS Code, Cursor or a terminal.
- **Waits stretch.** Once the session goes quiet the Mac may idle-sleep, and a 90-second wait once took 39 minutes. The script keeps the Mac awake while it waits and checks the clock rather than trusting `sleep`.
- **Permission prompts at night stall everything.** The first time your agent's app controls another app, macOS asks for permission. The skill checks your open apps as soon as you ask, so those prompts appear while you're still there to click Allow.
- **Unsaved work and running terminals block a shutdown.** The script saves what it can, then closes what still refuses.

## Install

### Claude Code: as a plugin (recommended)

In a Claude Code session:

```
/plugin marketplace add borun/mac-shutdown-skill
/plugin install mac-shutdown@mac-shutdown-skill
```

Or from a shell:

```bash
claude plugin marketplace add borun/mac-shutdown-skill
```

```bash
claude plugin install mac-shutdown@mac-shutdown-skill
```

To update later, run `claude plugin marketplace update mac-shutdown-skill`, then `claude plugin update mac-shutdown@mac-shutdown-skill`.

### Claude Code: as a plain skill

```bash
git clone https://github.com/borun/mac-shutdown-skill.git ~/src/mac-shutdown-skill
```

```bash
ln -s ~/src/mac-shutdown-skill/skills/mac-shutdown ~/.claude/skills/mac-shutdown
```

To update later, run `git -C ~/src/mac-shutdown-skill pull`.

### Other agents

With the [`skills` CLI](https://github.com/vercel-labs/skills) (Node.js 22.20+), which detects your installed agents:

```bash
npx skills add borun/mac-shutdown-skill -g
```

Or link `skills/mac-shutdown` from a clone into your agent's skills folder. `~/.agents/skills/` is read by Codex, Cursor, Gemini CLI, Copilot CLI, OpenCode, Goose, Amp and Devin Desktop:

```bash
mkdir -p ~/.agents/skills && ln -s ~/src/mac-shutdown-skill/skills/mac-shutdown ~/.agents/skills/mac-shutdown
```

### Upgrading from 1.x

Version 1 was cloned straight into `~/.claude/skills/mac-shutdown`. From 2.0 the skill lives in `skills/mac-shutdown/` inside the repo, so after a `git pull` that folder no longer holds a SKILL.md at its top. Either install the plugin as above and remove the old folder, or keep the clone elsewhere and link the skill folder:

```bash
mv ~/.claude/skills/mac-shutdown ~/src/mac-shutdown-skill && git -C ~/src/mac-shutdown-skill pull && ln -s ~/src/mac-shutdown-skill/skills/mac-shutdown ~/.claude/skills/mac-shutdown
```

Don't upgrade while a shutdown is scheduled. Your logs in `~/Library/Logs/mac-shutdown/` are kept.

## Use it

Just ask, in your own words:

- "I'm off to bed. Finish this, then shut my Mac down."
- "Shut my Mac down at 1:30 tonight."
- "If anything blocks the shutdown, close it. If nothing works, put it to sleep."
- "Cancel the shutdown."
- "Did my Mac shut down properly last night? Where did my drafts go?"

Your agent first runs a read-only preview and tells you what will happen to each open app. It then finishes the work, schedules the shutdown, and sends a short message with the start time, the log path and the exact cancel command.

To cancel, click **Cancel shutdown** on the warning, or run the cancel command from that message: `<skill folder>/scripts/mac_shutdown.sh cancel`.

### Running the script yourself

| Command | What it does |
|---|---|
| `mac_shutdown.sh preview` | Read-only: each open app and what will happen to it, unsaved drafts, terminal jobs, Docker, other users |
| `mac_shutdown.sh schedule --in 2m` | Shut down in 2 minutes (accepts `90s`, `5m`, `2h`) |
| `mac_shutdown.sh schedule --at 01:30` | Shut down at the next 01:30 (also accepts `"YYYY-MM-DD HH:MM"`) |
| `mac_shutdown.sh schedule --after-pid 1234` | Shut down after process 1234 exits |
| `mac_shutdown.sh schedule --dry-run` | Run every step now, read-only, and print what would happen |
| `mac_shutdown.sh status` | Is a shutdown scheduled, and when? |
| `mac_shutdown.sh cancel` | Cancel it |
| `mac_shutdown.sh last` | The latest run's log, plus macOS's own shutdown and start records |
| `mac_shutdown.sh doctor` | Read-only check: tools, your agent's app, permissions, other users, Docker, config |

More options for `schedule`:

| Option | What it does |
|---|---|
| `--warn SECONDS` | Length of the on-screen warning (default 60; `0` turns it off) |
| `--keep "App"` | Never quit or end this app (repeatable). If it blocks the shutdown, the Mac sleeps instead |
| `--no-kill` | Never force anything closed; if macOS refuses, the Mac sleeps |
| `--kill` | Force-close apps that refuse, even if your config says `no_kill=yes` |
| `--late-limit 30m` | Skip the shutdown if the run can only start this late, for example because the Mac slept through the start time. This stops it shutting the Mac down hours later while you're using it |
| `--save-dir DIR` | Where never-saved drafts go |
| `--replace` | Replace an existing schedule |

### Your defaults

To avoid repeating options, put them in `~/.config/mac-shutdown/config`, one per line. Flags still win.

```
# never touch Music, and let the Mac sleep rather than force anything closed
keep=Music
no_kill=yes
warn=120
save_dir=~/Documents/Drafts
```

Settings: `in`, `warn`, `late_limit`, `keep` (repeatable), `no_kill` (`yes` or `no`) and `save_dir`. Run `mac_shutdown.sh doctor` to check the file.

## What can be lost

Read this before you rely on it:

- **Apps the script can't save.** Drafts are saved automatically only in TextEdit, Pages, Numbers and Keynote. If another app refuses to quit, for example because a browser form is half filled in, the app is ended and that unsaved work is lost. The preview names these apps so you can save first. Use `--keep` or `--no-kill` if you'd rather the Mac slept than lose anything.
- **Every session in your agent's app.** Ending that app stops every session in it, not just the one that scheduled the shutdown. The skill checks for other running sessions first.
- **Jobs in terminals and Docker.** Terminal jobs are stopped. A throwaway container started in the last 30 minutes, such as a test run, is flagged in the preview so your agent can wait for it. Containers with no restart policy don't come back on their own when Docker starts again; the preview and the log name them.

## Requirements

- macOS (tested on macOS 26), with the system's own `/bin/bash`, `osascript`, `caffeinate`, `pmset` and `perl`. No installs needed.
- An agent that can run shell commands: Claude Code (the desktop app or the CLI), or another agent that supports skills.
- Permission for your agent's app to control System Events, and any document app you want saved. macOS asks the first time; the preview triggers these prompts early. `doctor` shows whether it's allowed.
- No `sudo` and no password needed.

Limits:
- If more than one user is logged in, macOS wants an admin password to shut down, so the Mac sleeps instead.
- Closing a laptop lid sleeps the Mac whatever the script does. Before the start time, a wake more than `--late-limit` late skips the run. Once the steps have begun, any sleep stops the run when the Mac wakes. Either way, nothing is closed under you; ask your agent to schedule again.

## Testing

- `bash tests/run.sh`: 108 safe unit tests. They fake `osascript`, `pmset`, `docker`, the clock and the process list, and only ever end dummy processes they started themselves, so nothing on your Mac is touched. CI runs them on macOS on every push, plus ShellCheck.
- `mac_shutdown.sh schedule --dry-run`: runs every step against your real apps, read-only.
- **Rehearsal switch:** while a file named `REHEARSAL` exists in `~/Library/Logs/mac-shutdown/`, every `schedule` becomes a dry run. Use it to test the skill end to end with your agent without turning anything off, and delete it afterwards.
- `evals/`: two test cases that compare an agent with and without the skill. Run them with `claude plugin eval .` from the repo root, with the rehearsal switch on.

## Layout

```text
skills/mac-shutdown/SKILL.md                  the instructions the agent follows
skills/mac-shutdown/scripts/mac_shutdown.sh   the script that does the work
.claude-plugin/                               Claude Code plugin and marketplace manifests
tests/run.sh                                  unit tests
evals/                                        test cases for the agent's behaviour
```

## Licence

[MIT](LICENSE)

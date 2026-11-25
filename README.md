# mac-shutdown

A [Claude Code](https://claude.com/claude-code) skill that shuts your Mac down gracefully once Claude has finished its work, or at a time you choose.

Tell Claude "finish the tests, push if they pass, then shut down my Mac", and it does the work, schedules the shutdown, and tells you how to cancel it. The next morning, ask "did my Mac shut down properly?" and it reads the log back to you.

## What it does

When the time comes, a small background script works down this list until the Mac is off:

1. Shows a 60-second warning with **Cancel shutdown** and **Shut down now** buttons. If nobody answers, it carries on.
2. Stops Docker Desktop gracefully, and OrbStack or Colima if they're running. Each container gets its own stop timeout and keeps its restart policy.
3. Saves drafts in TextEdit, Pages, Numbers and Keynote. Documents with a file are saved in place; never-saved drafts go to `~/Documents/Saved before shutdown/<date time>/`. Every path is logged.
4. Asks every other app to quit.
5. Closes terminals, after logging what was running in them.
6. Asks macOS to shut down.
7. If an app refuses (the Claude app usually does), it ends that app and asks again.
8. If the Mac still won't shut down, it puts it to sleep instead.

Every step is logged in `~/Library/Logs/mac-shutdown/`.

## Why it's a skill and not a one-liner

`osascript -e 'tell application "System Events" to shut down'` looks like enough, but it fails when Claude runs it:

- **The Claude desktop app refuses to quit,** and one refusing app cancels the whole shutdown. A Claude session also can't quit its own app. The shutdown has to run from a separate process that outlives the app and can end it.
- **Waits stretch.** Once the session goes quiet the Mac may idle-sleep, and a 90-second wait once took 39 minutes. The script keeps the Mac awake while it waits and checks the clock rather than trusting `sleep`.
- **Permission prompts at night stall everything.** The first time Claude controls an app, macOS asks for permission. The skill checks your open apps as soon as you ask, so those prompts appear while you're still there to click Allow.
- **Unsaved work and running terminals block a shutdown.** The script saves what it can, then closes what still refuses.

## Install

Clone it into your personal skills folder:

```bash
git clone https://github.com/borun/mac-shutdown-skill.git ~/.claude/skills/mac-shutdown
```

Start a new Claude Code session and the skill is available in every project. To update it later:

```bash
git -C ~/.claude/skills/mac-shutdown pull
```

## Use it

Just ask, in your own words:

- "I'm off to bed. Finish this, then shut my Mac down."
- "Shut my Mac down at 1:30 tonight."
- "If anything blocks the shutdown, close it. If nothing works, put it to sleep."
- "Cancel the shutdown."
- "Did my Mac shut down properly last night? Where did my drafts go?"

Claude first runs a read-only preview and tells you what will happen to each open app. It then finishes the work, schedules the shutdown, and sends a short message with the start time, the log path and how to cancel.

To cancel, click **Cancel shutdown** on the warning, or run:

```bash
~/.claude/skills/mac-shutdown/scripts/mac_shutdown.sh cancel
```

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

More options for `schedule`:

| Option | What it does |
|---|---|
| `--warn SECONDS` | Length of the on-screen warning (default 60; `0` turns it off) |
| `--keep "App"` | Never quit or end this app (repeatable). If it blocks the shutdown, the Mac sleeps instead |
| `--no-kill` | Never force anything closed; if macOS refuses, the Mac sleeps |
| `--late-limit 30m` | Skip the shutdown if the run can only start this late, for example because the Mac slept through the start time. This stops it shutting the Mac down hours later while you're using it |
| `--save-dir DIR` | Where never-saved drafts go |
| `--replace` | Replace an existing schedule |

## What can be lost

Read this before you rely on it:

- **Apps the script can't save.** Drafts are saved automatically only in TextEdit, Pages, Numbers and Keynote. If another app refuses to quit, for example because a browser form is half filled in, the app is ended and that unsaved work is lost. The preview names these apps so you can save first. Use `--keep` or `--no-kill` if you'd rather the Mac slept than lose anything.
- **Every Claude session.** Ending the Claude app stops every session in it, not just the one that scheduled the shutdown. The skill checks for other running sessions first.
- **Jobs in terminals and Docker.** Terminal jobs are stopped. A throwaway container started in the last 30 minutes, such as a test run, is flagged in the preview so Claude can wait for it. Containers with no restart policy don't come back on their own when Docker starts again; the preview and the log name them.

## Requirements

- macOS (tested on macOS 26), with the system's own `/bin/bash`, `osascript`, `caffeinate` and `pmset`. No installs needed.
- Claude Code: the desktop app or the CLI.
- Permission for Claude to control System Events, and any document app you want saved. macOS asks the first time; the preview triggers these prompts early.
- No `sudo` and no password needed.

Limits: if more than one user is logged in, macOS wants an admin password to shut down, so the Mac sleeps instead. Closing a laptop lid sleeps the Mac whatever the script does; if it then wakes more than `--late-limit` after the start time, the shutdown is skipped.

## Testing

- `bash tests/run.sh`: 58 safe unit tests. They fake `osascript`, `pmset` and `docker`, and only ever end dummy processes they started themselves, so nothing on your Mac is touched. CI runs them on macOS on every push.
- `mac_shutdown.sh schedule --dry-run`: runs every step against your real apps, read-only.
- **Rehearsal switch:** while a file named `REHEARSAL` exists in `~/Library/Logs/mac-shutdown/`, every `schedule` becomes a dry run. Use it to test the skill end to end with Claude without turning anything off, and delete it afterwards.
- `evals/`: two test cases in skill-creator's format (`claude plugin eval` reads them). They compare Claude with and without the skill; run them with the rehearsal switch on.

## Layout

```text
SKILL.md                 the instructions Claude follows
scripts/mac_shutdown.sh  the script that does the work
tests/run.sh             unit tests
evals/                   test cases for Claude's behaviour
```

## Licence

[MIT](LICENSE)

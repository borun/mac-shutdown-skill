# Changelog

## 2.0.0 (2026-11-26)

**Install layout changed.** The skill now lives in `skills/mac-shutdown/`, and the repo is a Claude Code plugin. If you cloned 1.x into `~/.claude/skills/mac-shutdown`, see "Upgrading from 1.x" in the README.

Fixes:
- **A sleep partway through no longer leads to closed apps on wake.** `caffeinate` only stops idle sleep, so a closed lid still slept the Mac, and the late-start check ran only before the first step. If the Mac slept during the steps, the run carried on when it woke: it ended the apps someone had just opened and shut down under them. Every pause now notices a sleep, and the run stops with ABORTED in the log and a notification.
- **Passwords and tokens are hidden** in the terminal jobs that the preview and the log list, since both are read back into the agent's conversation (`--password X`, `TOKEN=X`, `user:pass@` in URLs, `Authorization: Bearer X`, `mysql -pX` and similar).
- **App names reach AppleScript as arguments**, so a name with a quote can't break the quit request.

New:
- **Works outside the Claude desktop app.** The script finds the app the agent runs in (Claude, VS Code, Cursor, a terminal) and quits it last; messages name that app, including where to grant Automation permission.
- **Plugin install:** `/plugin marketplace add borun/mac-shutdown-skill`, then `/plugin install mac-shutdown@mac-shutdown-skill`. Other agents can use `npx skills add borun/mac-shutdown-skill` or `~/.agents/skills/`.
- **Defaults in `~/.config/mac-shutdown/config`** (`in`, `warn`, `late_limit`, `keep`, `no_kill`, `save_dir`), and `--kill` to override `no_kill=yes` once.
- **`doctor`:** a read-only check of tools, the agent's app, Automation permission, other users, Docker and the config file.
- SKILL.md finds its script through `${CLAUDE_SKILL_DIR}`, so it works for plugin and plain installs.
- 108 unit tests (from 58): the sleep guard, the late-start skip, redaction, app detection, force-closing with `--keep` and `--no-kill`, cancelling a running worker, the config file and `doctor`.

## 1.0.0 (2026-11-25)

First release.

- Preview of open apps, unsaved drafts, terminal jobs, Docker containers and other logged-in users, before anything is scheduled.
- A detached worker that outlives the Claude app, keeps the Mac awake while it waits, and checks the clock instead of trusting `sleep`.
- A 60-second warning with Cancel; Docker, OrbStack and Colima stopped gracefully; drafts saved in TextEdit, Pages, Numbers and Keynote with their paths logged.
- Apps and terminals asked to quit; those that refuse are ended, with 45 seconds' grace for the Claude app. Sleep is the last resort.
- A late-start guard skips the shutdown if the Mac slept through the start time.
- `status`, `cancel` and `last` (the run's log plus macOS's shutdown and start records).
- Safe unit tests, a rehearsal switch for end-to-end tests, and skill-creator test cases.

These fixes came from the first real run:
- Only throwaway containers are flagged as running jobs; services that were just redeployed are not.
- The Claude app gets 45 seconds after TERM before KILL.
- LaunchServices error -10827 on the second shutdown request is logged as expected: macOS is already shutting down.

# Changelog

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

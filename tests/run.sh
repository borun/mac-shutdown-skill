#!/bin/bash
# Safe unit tests for scripts/mac_shutdown.sh.
#
# Nothing here can shut down, sleep or quit anything on the machine running the tests:
# osascript, pmset, docker and caffeinate are replaced by shell functions (which win over
# programs on PATH) before the script is loaded, and the only processes ended are dummy
# `sleep` processes the tests start themselves. Commands run as a separate process only
# with input that is rejected before anything starts, and with a REHEARSAL file in a
# throwaway state folder as a second safety net.
#
# Run: bash tests/run.sh

# ECHO, KEEP and SHUTDOWN_GRACE are set here and read by the sourced script.
# shellcheck disable=SC2034

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/mac_shutdown.sh"

# ---------------------------------------------------------------- fakes
FAKE_OSA_OUT=""
FAKE_OSA_RC=0
osascript() { printf '%s\n' "$FAKE_OSA_OUT"; return "$FAKE_OSA_RC"; }
pmset() { echo "fake pmset $*"; return 0; }
docker() { return 1; }
caffeinate() { return 0; }

STATE="$(mktemp -d -t mac-shutdown-tests)"
export MAC_SHUTDOWN_STATE_DIR="$STATE"
touch "$STATE/REHEARSAL"
trap 'rm -rf "$STATE"' EXIT

# shellcheck source=../scripts/mac_shutdown.sh
MAC_SHUTDOWN_LIB=1 . "$SCRIPT"
set +e   # the script sets -u only; keep going after a failed check
LOG="$STATE/test.log"
ECHO=0

# ---------------------------------------------------------------- helpers
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; shift; for line in "$@"; do echo "      $line"; done; }
check() {   # name, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi
}
contains() {   # name, needle, haystack
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing:  $2" "in:       $3" ;; esac
}
lacks() {   # name, needle, haystack
  case "$3" in *"$2"*) bad "$1" "unexpected: $2" "in:         $3" ;; *) ok "$1" ;; esac
}
log_since() { tail -n +"$(( $1 + 1 ))" "$LOG"; }
log_lines() { wc -l < "$LOG" | tr -d ' '; }
: > "$LOG"

# ---------------------------------------------------------------- durations
check "duration 90s" 90 "$(parse_duration 90s)"
check "duration 5m" 300 "$(parse_duration 5m)"
check "duration 2h" 7200 "$(parse_duration 2h)"
check "duration plain seconds" 45 "$(parse_duration 45)"
for v in 5x m -5m 1.5h ""; do
  ( parse_duration "$v" ) >/dev/null 2>&1
  check "duration rejects '$v'" 2 "$?"
done

# ---------------------------------------------------------------- clock times
NOW=$(date +%s)
t=$(parse_at "$(date -v+2H +%H:%M)")
if [ "$t" -gt "$NOW" ] && [ $(( t - NOW )) -le 86400 ]; then ok "a time 2 h ahead is within the next day"; else bad "a time 2 h ahead is within the next day" "got $t, now $NOW"; fi
t=$(parse_at "$(date -v-2H +%H:%M)")
if [ "$t" -gt "$NOW" ] && [ $(( t - NOW )) -le 86400 ]; then ok "a time 2 h ago means its next occurrence"; else bad "a time 2 h ago means its next occurrence" "got $t, now $NOW"; fi
t=$(parse_at "$(date -v+1d '+%Y-%m-%d') 10:00")
check "a full date and time" "$(date -v+1d '+%Y-%m-%d') 10:00" "$(date -r "$t" '+%Y-%m-%d %H:%M')"
for v in 25:00 1:3 "2020-01-01 10:00" tonight; do
  ( parse_at "$v" ) >/dev/null 2>&1
  check "time rejects '$v'" 2 "$?"
done

# ---------------------------------------------------------------- app kinds and --keep
check "Finder is left to macOS" finder "$(app_kind com.apple.finder)"
check "the Claude app" claude "$(app_kind com.anthropic.claudefordesktop)"
check "Terminal" terminal "$(app_kind com.apple.Terminal)"
check "iTerm2" terminal "$(app_kind com.googlecode.iterm2)"
check "TextEdit saves drafts" doc "$(app_kind com.apple.TextEdit)"
check "Pages saves drafts" doc "$(app_kind com.apple.Pages)"
check "Docker Desktop" engine "$(app_kind com.electron.dockerdesktop)"
check "anything else" other "$(app_kind com.apple.Safari)"
check "Pages extension" .pages "$(doc_ext com.apple.Pages)"
case "$(doc_ext com.apple.TextEdit)" in .txt|.rtf) ok "TextEdit extension follows its Format setting" ;; *) bad "TextEdit extension" "got $(doc_ext com.apple.TextEdit)" ;; esac
KEEP="|Safari|com.example.keepme"
is_kept Safari com.apple.Safari; check "--keep by name" 0 "$?"
is_kept Other com.example.keepme; check "--keep by bundle id" 0 "$?"
is_kept Chrome com.google.Chrome; check "--keep leaves others alone" 1 "$?"
KEEP=""

# ---------------------------------------------------------------- timeouts and process trees
start=$(date +%s); with_timeout 1 sleep 10; rc=$?
check "with_timeout stops a slow command" 124 "$rc"
if [ $(( $(date +%s) - start )) -le 4 ]; then ok "with_timeout returns promptly"; else bad "with_timeout returns promptly" "took $(( $(date +%s) - start )) s"; fi
sleep 30 & child=$!
contains "proc_tree lists child processes" "sleep 30" "$(proc_tree $$)"
kill "$child" 2>/dev/null; wait "$child" 2>/dev/null

# ---------------------------------------------------------------- ending processes
# Short sleeps, so no orphaned child keeps the output open once the dummy is killed.
bash -c 'trap "" TERM; while :; do sleep 1; done' & stubborn=$!
sleep 1
n=$(log_lines); end_process "$stubborn" stubborn-dummy 2 2>/dev/null
out=$(log_since "$n")
contains "a process that ignores TERM gets KILL after its grace" "did not close within 2s of TERM; sending KILL" "$out"
contains "and it ends" "stubborn-dummy has ended" "$out"
wait "$stubborn" 2>/dev/null
sleep 60 & polite=$!
n=$(log_lines); start=$(date +%s); end_process "$polite" polite-dummy 2>/dev/null
out=$(log_since "$n")
contains "the default grace is 15 s" "it has 15s to close by itself" "$out"
lacks "a process that exits on TERM gets no KILL" "sending KILL" "$out"
if [ $(( $(date +%s) - start )) -le 4 ]; then ok "and it is not kept waiting"; else bad "and it is not kept waiting" "took $(( $(date +%s) - start )) s"; fi
wait "$polite" 2>/dev/null
check "the Claude app gets longer before KILL" 45 "$CLAUDE_TERM_GRACE"

# ---------------------------------------------------------------- Docker notes
N=$(date +%s)
docker_containers() {
  echo "demo-api-1|$(( N - 300 ))|unless-stopped|false|demo-backend:1"
  echo "e2e-run|$(( N - 180 ))|no|true|mcr.microsoft.com/playwright:v1"
  echo "old-cache|$(( N - 50000 ))|no|false|redis:8"
}
out=$(docker_notes preview)
contains "counts running containers" "3 containers are running" "$out"
contains "flags a throwaway job that just started" "wait for it before scheduling: e2e-run" "$out"
lacks "does not flag a service that was just redeployed" "demo-api-1" "$out"
contains "names a container with no restart policy" "come back on their own when Docker starts again: old-cache" "$out"
lacks "does not list a self-deleting job as 'won't come back'" "again: e2e-run" "$out"
contains "at shutdown time it says the job is cut off" "is cut off when Docker stops: e2e-run" "$(docker_notes run)"

# ---------------------------------------------------------------- shutdown request, with fake osascript
SHUTDOWN_GRACE=0
list_apps() { printf 'Finder\t1\tcom.apple.finder\n'; }
FAKE_OSA_OUT="63:72: execution error: An error of type -10827 has occurred. (-10827)"; FAKE_OSA_RC=1
n=$(log_lines); attempt_shutdown 2
out=$(log_since "$n")
contains "-10827 is explained as macOS already shutting down" "that error is expected: macOS is already shutting down" "$out"
contains "a refused shutdown is reported" "an app refused the shutdown or is still holding it up" "$out"
FAKE_OSA_OUT=""; FAKE_OSA_RC=0
n=$(log_lines); attempt_shutdown 1
lacks "a clean answer gets no error note" "that error is expected" "$(log_since "$n")"

# ---------------------------------------------------------------- the command line, as a separate process
# Each of these is rejected before anything starts; REHEARSAL in the state folder is a second guard.
for args in "--in 5x" "--at 25:00" "--warn abc" "--after-pid abc" "--late-limit 1x" "--bogus"; do
  # shellcheck disable=SC2086  # the arguments are split on purpose
  /bin/bash "$SCRIPT" schedule $args >/dev/null 2>&1
  check "schedule rejects: $args" 2 "$?"
done
if [ -e "$STATE/scheduled.pid" ]; then bad "no worker was started" "found $STATE/scheduled.pid"; else ok "no worker was started"; fi
contains "status with nothing scheduled" "No shutdown is scheduled." "$(/bin/bash "$SCRIPT" status)"
contains "status shows the rehearsal switch" "REHEARSAL MODE is on" "$(/bin/bash "$SCRIPT" status)"
contains "cancel with nothing scheduled" "No shutdown is scheduled." "$(/bin/bash "$SCRIPT" cancel)"
contains "help shows the commands" "mac_shutdown.sh schedule [options]" "$(/bin/bash "$SCRIPT" help)"

# ---------------------------------------------------------------- summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

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
SCRIPT="$HERE/../skills/mac-shutdown/scripts/mac_shutdown.sh"

# ---------------------------------------------------------------- fakes
FAKE_OSA_OUT=""
FAKE_OSA_RC=0
osascript() { printf '%s\n' "$FAKE_OSA_OUT"; return "$FAKE_OSA_RC"; }
pmset() { echo "fake pmset $*"; return 0; }
docker() { return 1; }
caffeinate() { return 0; }

STATE="$(mktemp -d -t mac-shutdown-tests)"
export MAC_SHUTDOWN_STATE_DIR="$STATE"
export MAC_SHUTDOWN_CONFIG="$STATE/config"   # never the real one; created only by the config tests
touch "$STATE/REHEARSAL"
trap 'rm -rf "$STATE"' EXIT

# shellcheck source=../skills/mac-shutdown/scripts/mac_shutdown.sh
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
check "the Claude app is an assistant host" host "$(app_kind com.anthropic.claudefordesktop)"
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

# ---------------------------------------------------------------- secrets in command lines
r=$(printf '%s\n' \
  "1 mysql -uroot -pS3cret appdb" \
  "2 psql postgres://app:hunter2@db:5432/app" \
  "3 curl -H Authorization: Bearer abc.def https://api.example.com" \
  "4 env GITHUB_TOKEN=ghp_abc npm publish" \
  "5 tool --api-key=sk-123 --password hunter2 --port 8080" \
  "6 curl https://x.com/a?api_key=abc&page=2" \
  "7 redis-cli -a SuperSecret" \
  "8 ./deploy aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5z" \
  "9 docker run -p 8080:80 nginx --bypass cache" | redact_secrets)
for secret in S3cret hunter2 abc.def ghp_abc sk-123 "api_key=abc" SuperSecret aB3dE5fG7hI9; do
  lacks "command lines hide: $secret" "$secret" "$r"
done
contains "the URL keeps its host" "postgres://***:***@db:5432/app" "$r"
contains "ordinary flags are kept" "docker run -p 8080:80 nginx --bypass cache" "$r"
contains "other query parameters are kept" "page=2" "$r"
bash -c 'sleep 30; :' --password hunter2 & child=$!
sleep 1
out=$(proc_tree $$)
contains "proc_tree shows the job" "--password ***" "$out"
lacks "but not its password" "hunter2" "$out"
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
check "the assistant's app gets longer before KILL" 45 "$HOST_TERM_GRACE"

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

# ---------------------------------------------------------------- the Mac sleeping before or during a run
# A fake clock: each "sleep" moves it on by an hour, as a closed lid would.
rm -f "$SLEPT_MARK"
( GUARD=1; FAKE_T=1000; now() { echo "$FAKE_T"; }; sleep() { FAKE_T=$(( FAKE_T + 3600 )); }; nap 5 )
contains "a pause that overran by an hour is recorded as a sleep" "a 5-second pause took 3600 seconds" "$(cat "$SLEPT_MARK" 2>/dev/null)"
n=$(log_lines); ( GUARD=1; DRY=1; guard_awake; log "carried on" )
out=$(log_since "$n")
contains "after a sleep mid-run, the run stops" "ABORTED: the Mac was asleep during the shutdown" "$out"
lacks "and none of the later steps run" "carried on" "$out"
check "and the record of the sleep is cleared" "" "$(cat "$SLEPT_MARK" 2>/dev/null)"
( GUARD=0; FAKE_T=1000; now() { echo "$FAKE_T"; }; sleep() { FAKE_T=$(( FAKE_T + 3600 )); }; nap 5 )
check "before the steps begin, a long pause is left to the late limit" "" "$(cat "$SLEPT_MARK" 2>/dev/null)"
( GUARD=1; nap 1 )
check "a normal pause is not taken for a sleep" "" "$(cat "$SLEPT_MARK" 2>/dev/null)"
check "with no sleep, the run carries on" "continued" "$( ( GUARD=1; guard_awake; echo continued ) )"
n=$(log_lines); ( DRY=1; MS_AFTER_PID=""; MS_DELAY=0; MS_LATE=1800; MS_TARGET=$(( $(date +%s) - 7200 )); phase_wait; log "carried on" )
out=$(log_since "$n")
contains "a run that can only start 2 h late is skipped" "SKIPPED: the run only got going 120 min after its start time" "$out"
lacks "and nothing else happens" "carried on" "$out"
check "an on-time run arms the sleep guard" "GUARD=1" "$( ( DRY=1; MS_AFTER_PID=""; MS_DELAY=0; MS_LATE=1800; MS_TARGET=$(date +%s); phase_wait; echo "GUARD=$GUARD" ) | tail -n 1)"

# ---------------------------------------------------------------- the app the assistant runs in
mkdir -p "$STATE/Apps/Claude.app" "$STATE/Lib/claude-code/claude.app" "$STATE/Apps/Visual Studio Code.app"
# Fake process tables ("PPID executable" per pid). Defined here, not inside $( ), which bash 3.2 can't
# parse with a case statement in it.
fake_app_info() { printf 'id.%s\t%s\n' "$(basename "$1" .app | tr ' ' '-')" "$(basename "$1" .app)"; }
chain_claude() {
  case "$1" in
    300) echo "200 /bin/zsh" ;;
    200) echo "100 $STATE/Lib/claude-code/claude.app/Contents/MacOS/claude" ;;
    100) echo "1 $STATE/Apps/Claude.app/Contents/MacOS/Claude" ;;
  esac
}
chain_vscode() {
  case "$1" in
    300) echo "200 /bin/zsh" ;;
    200) echo "1 $STATE/Apps/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper" ;;
  esac
}
chain_tmux() {
  case "$1" in
    300) echo "200 /bin/zsh" ;;
    200) echo "1 /usr/bin/tmux" ;;
  esac
}
host=$( proc_info() { chain_claude "$@"; }; app_info() { fake_app_info "$@"; }; detect_host 300 )
check "the highest app in the process chain is the host, not a tool's own bundle" "id.Claude${TAB}Claude" "$host"
host=$( proc_info() { chain_vscode "$@"; }; app_info() { fake_app_info "$@"; }; detect_host 300 )
check "a helper inside an app counts as the app (and names with spaces work)" "id.Visual-Studio-Code${TAB}Visual Studio Code" "$host"
host=$( proc_info() { chain_tmux "$@"; }; detect_host 300 )
check "no app in the chain (tmux, ssh): no host" "" "$host"
check "the detected host is quit last" host "$( HOST_ID=com.todesktop.cursor; app_kind com.todesktop.cursor )"
check "a terminal that hosts the session is still handled as a terminal" terminal "$( HOST_ID=com.apple.Terminal; app_kind com.apple.Terminal )"

# ---------------------------------------------------------------- AppleScript gets names as arguments
( osascript() { printf '%s\n' "$@" > "$STATE/osa-args"; }; quit_app_async 'Odd "Name" App' 10; wait )
check "an app name is passed as one argument, never pasted into the script" 1 "$(grep -c 'Odd' "$STATE/osa-args")"
contains "and arrives intact" 'Odd "Name" App' "$(tail -n 1 "$STATE/osa-args")"
n=$(log_lines)
( osascript() { printf '%s\n' "$@" > "$STATE/osa-args"; echo "button returned:, gave up:true"; }
  HOST_NAME=Cursor; MS_WARN=5; DRY=0; phase_warn )
contains "the warning names the assistant's app" "as you asked your assistant in Cursor." "$(cat "$STATE/osa-args")"
contains "and an unanswered warning carries on" "nobody answered the warning; carrying on" "$(log_since "$n")"

# ---------------------------------------------------------------- ending apps: --keep and --no-kill
sleep 60 & dummy=$!
sleep 60 & kept=$!
n=$(log_lines)
( list_apps() { printf 'Dummy\t%s\tcom.example.dummy\nKept\t%s\tcom.example.kept\n' "$dummy" "$kept"; }
  DRY=0; MS_KILL=1; KEEP="|Kept"; TERM_GRACE=2; GUARD=0; phase_force )
out=$(log_since "$n")
if alive "$dummy"; then bad "an app that refused is ended" "pid $dummy is alive"; else ok "an app that refused is ended"; fi
if alive "$kept"; then ok "a --keep app is never ended"; else bad "a --keep app is never ended" "pid $kept was ended"; fi
contains "and the log says so" "Kept: kept (--keep); not ended" "$out"
n=$(log_lines)
( list_apps() { printf 'Kept\t%s\tcom.example.kept\n' "$kept"; }; DRY=0; MS_KILL=0; GUARD=0; phase_force )
contains "--no-kill ends nothing" "--no-kill: nothing is forced closed" "$(log_since "$n")"
if alive "$kept"; then ok "and the app is still running"; else bad "and the app is still running" "pid $kept was ended"; fi
kill "$kept" 2>/dev/null; wait "$dummy" "$kept" 2>/dev/null

# ---------------------------------------------------------------- cancelling a running worker
# A dummy whose command line contains "mac_shutdown", as the real worker's does. Short sleeps, so
# nothing it leaves behind keeps the output open.
bash -c 'while :; do sleep 1; done' mac_shutdown_dummy >/dev/null 2>&1 & worker_dummy=$!
sleep 1
printf '%s %s\n' "$worker_dummy" "$(ps -o pgid= -p $$ | tr -d ' ')" > "$PID_FILE"
out=$(cmd_cancel 2>&1)
contains "cancel ends a scheduled worker" "Cancelled the scheduled shutdown (worker $worker_dummy)" "$out"
if alive "$worker_dummy"; then bad "the worker is gone after cancel" "pid $worker_dummy is alive"; kill -KILL "$worker_dummy"; else ok "the worker is gone after cancel"; fi
check "cancel leaves a note for the worker's log" yes "$( [ -f "$CANCEL_MARK" ] && echo yes || echo no )"
check "and clears the schedule" no "$( [ -f "$PID_FILE" ] && echo yes || echo no )"
rm -f "$CANCEL_MARK"; wait "$worker_dummy" 2>/dev/null

# ---------------------------------------------------------------- config file and doctor
printf '%s\n' "# my defaults" "in = 5m" "warn=10" "keep=Music" "keep = Spotify" "no_kill=yes" "save_dir=~/Drafts" > "$CONFIG_FILE"
got=$( parse_opts; printf '%s|%s|%s|%s|%s' "$OPT_DELAY" "$OPT_WARN" "$KEEP" "$OPT_KILL" "$OPT_SAVE_DIR" )
check "the config file sets the defaults" "300|10||Music|Spotify|0|$HOME/Drafts" "$got"
got=$( parse_opts --warn 30 --kill --keep Mail; printf '%s|%s|%s' "$OPT_WARN" "$OPT_KILL" "$KEEP" )
check "flags win over the config file, and --keep adds to it" "30|1||Music|Spotify|Mail" "$got"
printf '%s\n' "warn=soon" > "$CONFIG_FILE"
( parse_opts ) >/dev/null 2>&1; check "a bad value in the config is refused" 2 "$?"
printf '%s\n' "colour=blue" > "$CONFIG_FILE"
contains "an unknown setting is named" "unknown setting 'colour'" "$( ( parse_opts ) 2>&1 )"
rm -f "$CONFIG_FILE"
FAKE_OSA_OUT="312"; FAKE_OSA_RC=0
out=$(HOST_NAME=Claude HOST_ID=com.anthropic.claudefordesktop cmd_doctor 2>&1)
contains "doctor names the assistant's app" "Assistant app:  Claude (com.anthropic.claudefordesktop)" "$out"
contains "doctor checks Automation" "System Events can be controlled" "$out"
contains "doctor reports the rehearsal switch" "REHEARSAL MODE is on" "$out"
FAKE_OSA_OUT="execution error: Not authorized to send Apple events to System Events. (-1743)"; FAKE_OSA_RC=1
contains "doctor explains a missing permission" "Allow Claude to control System Events" "$(HOST_NAME=Claude HOST_ID=x cmd_doctor 2>&1)"
FAKE_OSA_OUT=""; FAKE_OSA_RC=0

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
contains "version" "mac-shutdown 2." "$(/bin/bash "$SCRIPT" version)"

# ---------------------------------------------------------------- summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

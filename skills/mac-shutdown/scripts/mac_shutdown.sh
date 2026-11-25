#!/bin/bash
# mac_shutdown.sh: a graceful, unattended shutdown of this Mac, with a logged escalation ladder.
#
#   mac_shutdown.sh preview [--keep APP] [--no-kill]   read-only: what would be saved, quit, stopped or ended
#   mac_shutdown.sh schedule [options]                 start the detached worker (or a dry run)
#   mac_shutdown.sh cancel                             stop a scheduled shutdown
#   mac_shutdown.sh status                             is one scheduled? when? which log?
#   mac_shutdown.sh last                               the latest run's log, and when the Mac last started
#
# schedule options:
#   --in DURATION     wait this long first: 90s, 5m, 2h (default 2m, so Claude's last reply can finish)
#   --at TIME         start at a local time: HH:MM (next time it comes round) or "YYYY-MM-DD HH:MM"
#   --after-pid PID   wait for this process to exit, then wait --in
#   --warn SECONDS    on-screen warning with a Cancel button before anything happens (default 60; 0 = none)
#   --keep APP        never quit or end this app (its name or bundle id); repeatable
#   --no-kill         never force anything closed; if macOS refuses to shut down, sleep instead
#   --late-limit DUR  skip the shutdown if the run only gets going this long after its start time,
#                     e.g. the Mac slept through it (default 30m; 0 = never skip)
#   --save-dir DIR    where never-saved drafts go (default ~/Documents/Saved before shutdown/<time>)
#   --dry-run         run every step now, in the foreground, read-only, printing what it would do
#   --replace         cancel an already scheduled shutdown first
#
# The ladder, once the wait is over:
#   warning with Cancel -> stop Docker/OrbStack/Colima -> save drafts in TextEdit, Pages, Numbers, Keynote
#   -> ask every app to quit -> close terminals (end them if they refuse) -> ask macOS to shut down
#   -> still on: end the apps that refused (the Claude app among them), ask again -> still on: sleep.
#
# If the Mac sleeps before the start time and wakes past --late-limit, the run is skipped. If it sleeps
# once the steps have begun (a closed lid; caffeinate only stops idle sleep), the run stops when it wakes.
#
# A file named REHEARSAL in the state folder turns every schedule into a dry run (for testing the skill).

set -u
PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PATH

STATE_DIR="${MAC_SHUTDOWN_STATE_DIR:-$HOME/Library/Logs/mac-shutdown}"
PID_FILE="$STATE_DIR/scheduled.pid"
INFO_FILE="$STATE_DIR/scheduled.txt"
CANCEL_MARK="$STATE_DIR/cancel-requested"
REHEARSAL_FILE="$STATE_DIR/REHEARSAL"
SAVE_ROOT="$HOME/Documents/Saved before shutdown"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SELF_DIR/$(basename "$0")"
TAB="$(printf '\t')"

TERMINAL_IDS="com.apple.Terminal com.googlecode.iterm2 dev.warp.Warp-Stable dev.warp.Warp com.mitchellh.ghostty org.alacritty io.alacritty net.kovidgoyal.kitty com.github.wez.wezterm co.zeit.hyper org.tabby"
CLAUDE_IDS="com.anthropic.claudefordesktop com.anthropic.claude"
DOC_IDS="com.apple.TextEdit com.apple.Pages com.apple.iWork.Pages com.apple.Numbers com.apple.iWork.Numbers com.apple.Keynote com.apple.iWork.Keynote"
ENGINE_IDS="com.electron.dockerdesktop com.docker.docker dev.kdrag0n.MacVirt"
NEVER_IDS="com.apple.finder"

SHUTDOWN_GRACE=150   # seconds to wait for macOS after asking it to shut down
QUIT_GRACE=60        # seconds for apps to quit after being asked
TERM_GRACE=15        # seconds between TERM and KILL
CLAUDE_TERM_GRACE=45 # the Claude app winds its sessions down, so it gets longer before KILL
SLEEP_GAP=90         # a pause that overruns by this much means the Mac slept (caffeinate only stops idle sleep)

LOG=""
ECHO=1
DRY=0
GUARD=0              # 1 once the shutdown steps have begun: from then on, a sleep stops the run
SLEPT_MARK="$STATE_DIR/slept-during-run"

# ---------------------------------------------------------------- helpers

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  local line
  line="$(ts) $*"
  if [ -n "$LOG" ]; then printf '%s\n' "$line" >> "$LOG"; fi
  if [ "$ECHO" = 1 ]; then printf '%s\n' "$line"; fi
  return 0
}
say() { printf '%s\n' "$*"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; }
die() { echo "mac_shutdown: $*" >&2; exit 2; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
alive() { kill -0 "$1" 2>/dev/null; }
now() { date +%s; }
fmt_time() { date -r "$1" '+%a %d %b %H:%M:%S'; }

# Sleep for $1 seconds. caffeinate stops idle sleep but not a closed lid, the Sleep menu or a flat
# battery, so if the pause overran by more than SLEEP_GAP the Mac was asleep: note it in SLEPT_MARK
# (a file, because many pauses run in subshells) for guard_awake to act on.
nap() {
  local before after
  before=$(now)
  sleep "$1"
  after=$(now)
  if [ "$GUARD" = 1 ] && [ $(( after - before )) -gt $(( $1 + SLEEP_GAP )) ]; then
    printf '%s: a %s-second pause took %s seconds\n' "$(ts)" "$1" "$(( after - before ))" >> "$SLEPT_MARK"
  fi
  return 0
}

# A notification in the corner of the screen. Arguments: title, text.
notify() {
  with_timeout 15 osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' "$1" "$2" >/dev/null 2>&1
}

# Between steps: if the Mac slept while the shutdown was under way, stop for good. Whoever wakes it
# is probably about to use it, and the later steps end apps and shut down.
guard_awake() {
  [ "$GUARD" = 1 ] && [ -s "$SLEPT_MARK" ] || return 0
  log "ABORTED: the Mac was asleep during the shutdown ($(tail -n 1 "$SLEPT_MARK")). Stopping here so nothing is closed under someone who has just woken it. The steps logged above had already run."
  if [ "$DRY" != 1 ]; then
    notify "Scheduled shutdown stopped" "The Mac went to sleep partway through the shutdown, so it was stopped when the Mac woke. See the log in $STATE_DIR."
  fi
  finish 0
}

# Run a command, killing it after $1 seconds (macOS has no timeout(1)). Returns 124 on timeout.
with_timeout() {
  local secs=$1 pid end
  shift
  "$@" &
  pid=$!
  end=$(( $(now) + secs ))
  while alive "$pid"; do
    if [ "$(now)" -ge "$end" ]; then
      kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    nap 1
  done
  wait "$pid"
}

# Visible apps, one per line: name<TAB>pid<TAB>bundle id
list_apps() {
  with_timeout 30 osascript \
    -e 'set out to ""' \
    -e 'tell application "System Events"' \
    -e 'repeat with p in (processes whose background only is false)' \
    -e 'set bid to ""' \
    -e 'try' -e 'set bid to (bundle identifier of p) as text' -e 'end try' \
    -e 'set out to out & (name of p) & tab & (unix id of p) & tab & bid & linefeed' \
    -e 'end repeat' -e 'end tell' -e 'return out' 2>/dev/null | sed '/^[[:space:]]*$/d'
}

app_kind() {
  local id=$1
  if in_list "$id" "$NEVER_IDS"; then echo finder
  elif in_list "$id" "$CLAUDE_IDS"; then echo claude
  elif in_list "$id" "$TERMINAL_IDS"; then echo terminal
  elif in_list "$id" "$DOC_IDS"; then echo doc
  elif in_list "$id" "$ENGINE_IDS"; then echo engine
  else echo other
  fi
}

KEEP=""
is_kept() {
  local name=$1 id=$2 k old_ifs=$IFS
  IFS='|'
  for k in $KEEP; do
    if [ -n "$k" ] && { [ "$k" = "$name" ] || [ "$k" = "$id" ]; }; then IFS=$old_ifs; return 0; fi
  done
  IFS=$old_ifs
  return 1
}

# The processes running inside an app (its descendants), for the log.
proc_tree() {
  ps -axo pid=,ppid=,command= | awk -v root="$1" '
    { pid = $1; ppid = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); cmd[pid] = $0; par[pid] = ppid }
    END {
      inset[root] = 1; changed = 1
      while (changed) { changed = 0; for (p in par) if (!(p in inset) && (par[p] in inset)) { inset[p] = 1; changed = 1 } }
      for (p in inset) if (p != root) print p " " substr(cmd[p], 1, 150)
    }' | sort -n | head -25
}

quit_app_async() {   # bundle id (or name), seconds
  local target=$1 secs=$2 spec
  if printf '%s' "$target" | grep -qE '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'; then spec="application id \"$target\""
  else spec="application \"$target\""; fi
  with_timeout "$secs" osascript -e "with timeout of $(( secs - 5 )) seconds" -e "tell $spec to quit" -e 'end timeout' >/dev/null 2>&1 &
}

# TERM, wait, then KILL. Arguments: pid name [seconds to wait after TERM]
end_process() {
  local pid=$1 name=$2 grace=${3:-$TERM_GRACE} i
  alive "$pid" || return 0
  log "  ending $name (pid $pid) with TERM; it has ${grace}s to close by itself"
  kill -TERM "$pid" 2>/dev/null
  i=0
  while alive "$pid" && [ $i -lt "$grace" ]; do nap 1; i=$((i + 1)); done
  if alive "$pid"; then
    log "  $name did not close within ${grace}s of TERM; sending KILL"
    kill -KILL "$pid" 2>/dev/null
    sleep 2
  fi
  if alive "$pid"; then log "  $name (pid $pid) is STILL running"; else log "  $name has ended"; fi
}

# Document apps: list or save their documents. Prints lines: STATUS<TAB>name<TAB>path-or-detail
doc_script() {   # bundle id, file to write
  local id=$1 out=$2 getpath emptycheck='-- no emptiness check for this app'
  if [ "$id" = com.apple.TextEdit ]; then
    getpath='try
				set pp to path of d
				if pp is not missing value then set p to pp
			end try'
    emptycheck='try
					if (text of d as text) is "" then set isMod to false
				end try'
  else
    getpath='try
				set ff to file of d
				if ff is not missing value then set p to my posixOf(ff)
			end try'
  fi
  cat > "$out" <<APPLESCRIPT
on run argv
	set mode to item 1 of argv
	set saveDir to item 2 of argv
	set ext to item 3 of argv
	set prefix to item 4 of argv
	set onlyName to ""
	if (count of argv) > 4 then set onlyName to item 5 of argv
	set report to ""
	tell application id "$id"
		set n to count of documents
		repeat with i from 1 to n
			set d to document i
			set dName to name of d
			set isMod to false
			try
				set isMod to modified of d
			end try
			set p to ""
			$getpath
			-- A draft that was never saved is kept unless it is empty, even when the app calls it unmodified.
			if p is "" and not isMod then
				set isMod to true
				$emptycheck
			end if
			if onlyName is not "" and dName is not onlyName then
				set report to report & "SKIPPED" & tab & dName & tab & "" & linefeed
			else if not isMod then
				set report to report & "CLEAN" & tab & dName & tab & p & linefeed
			else if mode is "list" then
				if p is "" then
					set report to report & "UNSAVED_NEW" & tab & dName & tab & (saveDir & "/" & prefix & " - " & my safeName(dName) & ext) & linefeed
				else
					set report to report & "UNSAVED" & tab & dName & tab & p & linefeed
				end if
			else
				try
					if p is "" then
						set target to saveDir & "/" & prefix & " - " & my safeName(dName) & ext
						save d in (my fileOf(target))
						set report to report & "SAVED_NEW" & tab & dName & tab & target & linefeed
					else
						save d
						set report to report & "SAVED" & tab & dName & tab & p & linefeed
					end if
				on error errMsg number errNum
					set report to report & "FAILED" & tab & dName & tab & errMsg & " (" & errNum & ")" & linefeed
				end try
			end if
		end repeat
	end tell
	return report
end run

on posixOf(f)
	return POSIX path of f
end posixOf

on fileOf(p)
	return POSIX file p
end fileOf

on safeName(s)
	set out to ""
	repeat with c in characters of s
		set c to c as text
		if c is "/" or c is ":" then set c to "-"
		set out to out & c
	end repeat
	return out
end safeName
APPLESCRIPT
}

doc_ext() {
  case "$1" in
    com.apple.TextEdit)   # new documents follow TextEdit's Format setting
      if [ "$(defaults read com.apple.TextEdit RichText 2>/dev/null)" = 0 ]; then echo .txt; else echo .rtf; fi ;;
    com.apple.Pages|com.apple.iWork.Pages) echo .pages ;;
    com.apple.Numbers|com.apple.iWork.Numbers) echo .numbers ;;
    com.apple.Keynote|com.apple.iWork.Keynote) echo .key ;;
    *) echo "" ;;
  esac
}

run_docs() {   # bundle id, list|save, display name, save dir [, only this document]
  local id=$1 mode=$2 name=$3 dir=$4 only=${5:-} f rc out
  f="$(mktemp -t mac_shutdown_docs)"
  doc_script "$id" "$f"
  out=$(with_timeout 90 osascript "$f" "$mode" "$dir" "$(doc_ext "$id")" "$name" "$only" 2>&1); rc=$?
  rm -f "$f"
  if [ $rc -ne 0 ]; then
    case "$out" in
      *-1743*) printf 'ERROR\t%s\t%s\n' "$name" "no permission to control $name: allow Claude in System Settings > Privacy & Security > Automation" ;;
      *) printf 'ERROR\t%s\t%s\n' "$name" "exit $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
    return 1
  fi
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'
}

# Running containers, one per line: name|started epoch|restart policy|auto-remove|image
docker_containers() {
  local ids name started policy autorm image t
  ids=$(docker ps -q 2>/dev/null)
  [ -n "$ids" ] || return 0
  # $ids is a list of ids, split on purpose.
  docker inspect -f '{{.Name}}|{{.State.StartedAt}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.AutoRemove}}|{{.Config.Image}}' $ids 2>/dev/null |
  while IFS='|' read -r name started policy autorm image; do
    t=${started%%.*}; t=${t%Z}
    t=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$t" +%s 2>/dev/null || echo 0)
    printf '%s|%s|%s|%s|%s\n' "${name#/}" "$t" "${policy:-no}" "$autorm" "$image"
  done
}

# Plain-language notes on the running containers: throwaway jobs that just started, and those with
# no restart policy. Argument: preview (before scheduling) or run (at shutdown time).
# A job is a throwaway container (removed when it ends, or no restart policy) started in the last
# 30 minutes, such as a test run. Services that were just redeployed (restart policy set) are not jobs.
docker_notes() {
  local when=${1:-preview} list recent="" norestart="" n name t policy autorm image age throwaway
  list=$(docker_containers)
  n=$(printf '%s\n' "$list" | grep -c .)
  echo "$n containers are running; each gets its own stop timeout."
  while IFS='|' read -r name t policy autorm image; do
    [ -n "$name" ] || continue
    throwaway=0
    if [ "$autorm" = true ]; then throwaway=1; fi
    case "$policy" in
      no|"") throwaway=1
             # A container that deletes itself when done was never meant to come back.
             if [ "$autorm" != true ]; then norestart="$norestart, $name"; fi ;;
    esac
    age=$(( ( $(now) - t ) / 60 ))
    if [ "$throwaway" = 1 ] && [ "$t" -gt 0 ] && [ "$age" -lt 30 ]; then
      recent="$recent; $name ($image, started $age min ago$( [ "$autorm" = true ] && echo ', removed when it ends'))"
    fi
  done <<CONTAINERS
$list
CONTAINERS
  if [ -n "$recent" ]; then
    if [ "$when" = run ]; then
      echo "!! A throwaway container started in the last 30 min, possibly a test or a build, is cut off when Docker stops: ${recent#; }"
    else
      echo "!! A throwaway container started in the last 30 min, so possibly a job still running (a test or a build); wait for it before scheduling: ${recent#; }"
    fi
  fi
  if [ -n "$norestart" ]; then
    echo "No restart policy, so these won't come back on their own when Docker starts again: ${norestart#, }"
  fi
}

docker_running() {
  command -v docker >/dev/null 2>&1 && docker desktop status 2>/dev/null | grep -qiE '^status[[:space:]]+running'
}

# ---------------------------------------------------------------- worker phases

WARN_SHOWING=0
on_term() {
  if [ "$WARN_SHOWING" = 1 ]; then
    osascript -e 'tell application "System Events" to quit' >/dev/null 2>&1   # closes the orphaned warning
  fi
  if [ -f "$CANCEL_MARK" ]; then
    log "CANCELLED: $(cat "$CANCEL_MARK" 2>/dev/null)"
    rm -f "$CANCEL_MARK"
  else
    log "the worker received a stop signal (most likely macOS is shutting down now)"
  fi
  cleanup
  exit 0
}

cleanup() {
  rm -f "$SLEPT_MARK"
  if [ "$DRY" != 1 ] && [ -f "$PID_FILE" ] && [ "$(cut -d' ' -f1 "$PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PID_FILE" "$INFO_FILE"
  fi
}

finish() { cleanup; log "=== worker finished ==="; exit "${1:-0}"; }
START_AT=0

phase_wait() {
  local target=$MS_TARGET
  if [ -n "$MS_AFTER_PID" ]; then
    log "waiting for process $MS_AFTER_PID to finish: $(ps -o command= -p "$MS_AFTER_PID" 2>/dev/null | cut -c1-100)"
    if [ "$DRY" = 1 ]; then log "[dry run] not waiting"
    else while alive "$MS_AFTER_PID"; do sleep 5; done; fi
    log "process $MS_AFTER_PID has finished"
    if [ $(( $(now) + MS_DELAY )) -gt "$target" ]; then target=$(( $(now) + MS_DELAY )); fi
  fi
  START_AT=$target
  log "waiting until $(fmt_time "$target"); idle sleep is held off meanwhile (caffeinate)"
  if [ "$DRY" = 1 ]; then log "[dry run] not waiting"
  else
    # Wall-clock loop: a plain long sleep can stretch for many minutes if the Mac naps.
    while [ "$(now)" -lt "$target" ]; do sleep 5; done
    log "the wait is over"
  fi
  # If the Mac slept through the start time (lid closed, power button), don't shut it down
  # hours later under someone who is using it.
  local late=$(( $(now) - target ))
  if [ "$MS_LATE" -gt 0 ] && [ "$late" -gt "$MS_LATE" ]; then
    log "SKIPPED: the run only got going $(( late / 60 )) min after its start time, past the $(( MS_LATE / 60 )) min late limit (the Mac was probably asleep). Nothing was shut down."
    if [ "$DRY" != 1 ]; then
      notify "Scheduled shutdown skipped" "The shutdown planned for $(fmt_time "$target") was skipped because the Mac was asleep at that time."
    fi
    finish 0
  fi
  # From here on the steps change things, so a sleep in the middle of them stops the run (guard_awake).
  GUARD=1
}

phase_warn() {
  local out rc
  [ "$MS_WARN" -gt 0 ] || { log "no on-screen warning (--warn 0)"; return 0; }
  if [ "$DRY" = 1 ]; then log "[dry run] would show a ${MS_WARN}-second warning with a Cancel button"; return 0; fi
  log "showing a ${MS_WARN}-second warning with a Cancel button"
  WARN_SHOWING=1
  out=$(with_timeout $(( MS_WARN + 30 )) osascript \
    -e "with timeout of $(( MS_WARN + 20 )) seconds" \
    -e 'tell application "System Events"' -e 'activate' \
    -e "display dialog \"This Mac will shut down in $MS_WARN seconds, as you asked Claude. Drafts in TextEdit, Pages, Numbers and Keynote will be saved first; other apps are asked to quit.\" with title \"Scheduled shutdown\" buttons {\"Cancel shutdown\", \"Shut down now\"} default button \"Shut down now\" cancel button \"Cancel shutdown\" with icon caution giving up after $MS_WARN" \
    -e 'end tell' -e 'end timeout' 2>&1); rc=$?
  WARN_SHOWING=0
  case "$out" in
    *-128*) log "CANCELLED: 'Cancel shutdown' was clicked on the warning"; finish 0 ;;
    *"gave up:true"*) log "nobody answered the warning; carrying on" ;;
    *"Shut down now"*) log "'Shut down now' was clicked; carrying on" ;;
    *) log "the warning could not be shown (exit $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)); carrying on" ;;
  esac
}

phase_engines() {
  log "--- step: container engines"
  local found=0
  if docker_running; then
    found=1
    docker_notes run | while IFS= read -r line; do log "Docker: $line"; done
    if [ "$DRY" = 1 ]; then log "[dry run] would stop Docker Desktop gracefully (docker desktop stop); containers get their own stop timeouts and restart policies are kept"
    else
      log "Docker Desktop is running; stopping it gracefully (docker desktop stop)"
      with_timeout 330 docker desktop stop --timeout 300 >> "$LOG" 2>&1
      if docker_running; then
        log "Docker Desktop is still running; asking the app to quit"
        quit_app_async com.docker.docker 60; nap 45
      fi
      if docker_running; then log "Docker Desktop is STILL running; the shutdown will stop it"; else log "Docker Desktop has stopped"; fi
    fi
  fi
  if pgrep -xq OrbStack; then
    found=1
    if [ "$DRY" = 1 ]; then log "[dry run] would stop OrbStack (orbctl stop, else quit the app)"
    else
      log "OrbStack is running; stopping it"
      if command -v orbctl >/dev/null 2>&1; then with_timeout 300 orbctl stop >> "$LOG" 2>&1; else quit_app_async dev.kdrag0n.MacVirt 120; nap 60; fi
    fi
  fi
  if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
    found=1
    if [ "$DRY" = 1 ]; then log "[dry run] would stop Colima (colima stop)"
    else log "Colima is running; stopping it"; with_timeout 300 colima stop >> "$LOG" 2>&1; fi
  fi
  [ $found = 1 ] || log "no container engine is running"
}

phase_save() {
  log "--- step: save drafts"
  local apps name pid id st dname detail any=0 out
  apps=$(list_apps)
  while IFS="$TAB" read -r name pid id; do
    [ -n "$name" ] || continue
    [ "$(app_kind "$id")" = doc ] || continue
    any=1
    if is_kept "$name" "$id"; then log "$name: kept (--keep); not touched"; continue; fi
    if [ "$DRY" = 1 ]; then
      out=$(run_docs "$id" list "$name" "$MS_SAVE_DIR")
    else
      mkdir -p "$MS_SAVE_DIR"
      out=$(run_docs "$id" save "$name" "$MS_SAVE_DIR")
    fi
    if [ -z "$out" ]; then log "$name: no open documents"; continue; fi
    while IFS="$TAB" read -r st dname detail; do
      case "$st" in
        CLEAN) log "$name: \"$dname\" has no unsaved changes" ;;
        UNSAVED) log "[dry run] $name: \"$dname\" would be saved in place: $detail" ;;
        UNSAVED_NEW) log "[dry run] $name: \"$dname\" was never saved; it would be saved as: $detail" ;;
        SAVED) log "SAVED $name: \"$dname\" saved in place: $detail" ;;
        SAVED_NEW) log "SAVED $name: \"$dname\" (never saved before) saved as: $detail" ;;
        FAILED) log "FAILED $name: \"$dname\" could not be saved: $detail" ;;
        ERROR) log "FAILED $name: $detail" ;;
        *) log "$name: $st $dname $detail" ;;
      esac
    done <<EOF
$out
EOF
  done <<EOF
$apps
EOF
  [ $any = 1 ] || log "no supported document app is open (TextEdit, Pages, Numbers, Keynote)"
  if [ "$DRY" != 1 ] && [ -d "$MS_SAVE_DIR" ] && [ -z "$(ls -A "$MS_SAVE_DIR" 2>/dev/null)" ]; then rmdir "$MS_SAVE_DIR" 2>/dev/null; fi
}

phase_quit() {
  log "--- step: ask apps to quit"
  local apps name pid id kind waiting="" i
  apps=$(list_apps)
  while IFS="$TAB" read -r name pid id; do
    [ -n "$name" ] || continue
    kind=$(app_kind "$id")
    case "$kind" in finder|claude|terminal) continue ;; esac
    if is_kept "$name" "$id"; then log "$name: kept (--keep); not asked to quit"; continue; fi
    if [ "$DRY" = 1 ]; then log "[dry run] would ask $name to quit"; continue; fi
    log "asking $name to quit"
    quit_app_async "${id:-$name}" "$QUIT_GRACE"
    waiting="$waiting $pid "
  done <<EOF
$apps
EOF
  [ "$DRY" = 1 ] && return 0
  [ -n "$waiting" ] || { log "no other apps to quit"; return 0; }
  i=0
  while [ $i -lt "$QUIT_GRACE" ]; do
    local left=0 p
    for p in $waiting; do alive "$p" && left=1; done
    [ $left = 0 ] && break
    nap 2; i=$((i + 2))
  done
  # Names may contain spaces, so look each pid up again rather than splitting the list.
  while IFS="$TAB" read -r name pid id; do
    case "$waiting" in *" $pid "*) alive "$pid" && log "$name did not quit (it may be asking about unsaved changes)" ;; esac
  done <<EOF
$apps
EOF
  log "apps still open: $(list_apps | cut -f1 | paste -sd, - | sed 's/,/, /g')"
}

phase_terminals() {
  log "--- step: terminals"
  local apps name pid id any=0
  apps=$(list_apps)
  while IFS="$TAB" read -r name pid id; do
    [ -n "$name" ] || continue
    [ "$(app_kind "$id")" = terminal ] || continue
    any=1
    log "$name is open; running inside it:"
    proc_tree "$pid" | while read -r line; do log "    $line"; done
    if is_kept "$name" "$id"; then log "$name: kept (--keep); left open, it may block the shutdown"; continue; fi
    if [ "$DRY" = 1 ]; then
      if [ "$MS_KILL" = 1 ]; then log "[dry run] would ask $name to quit, and end it if it is still open after 10 s"
      else log "[dry run] would ask $name to quit (--no-kill: it would be left open if it refuses)"; fi
      continue
    fi
    log "asking $name to quit"
    quit_app_async "$id" 15
    local i=0
    while alive "$pid" && [ $i -lt 10 ]; do nap 1; i=$((i + 1)); done
    guard_awake
    if alive "$pid"; then
      if [ "$MS_KILL" = 1 ]; then end_process "$pid" "$name"
      else log "$name is still open (--no-kill); it may block the shutdown"; fi
    else
      log "$name has quit"
    fi
  done <<EOF
$apps
EOF
  [ $any = 1 ] || log "no terminal app is open"
}

attempt_shutdown() {
  local n=$1 out rc waited=0
  if [ "$DRY" = 1 ]; then log "[dry run] would ask macOS to shut down (attempt $n) and wait up to ${SHUTDOWN_GRACE}s"; return 1; fi
  log "--- step: shutdown, attempt $n: asking macOS to shut down"
  out=$(with_timeout 60 osascript -e 'with timeout of 50 seconds' -e 'tell application "System Events" to shut down' -e 'end timeout' 2>&1); rc=$?
  log "macOS answered (exit $rc) $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  case "$out" in
    # LaunchServices won't start System Events once a shutdown is under way, and an app that has
    # already quit drops the connection: both mean the earlier request is going through.
    *-10827*|*-609*) log "  that error is expected: macOS is already shutting down (an earlier request went through once the app holding it up ended)" ;;
  esac
  while [ $waited -lt $SHUTDOWN_GRACE ]; do nap 5; guard_awake; waited=$((waited + 5)); done
  log "the Mac is still on ${SHUTDOWN_GRACE}s after attempt $n: an app refused the shutdown or is still holding it up"
  log "apps still open: $(list_apps | cut -f1 | paste -sd, - | sed 's/,/, /g')"
  return 1
}

phase_force() {
  log "--- step: end the apps that refused"
  local apps name pid id kind
  if [ "$MS_KILL" != 1 ]; then log "--no-kill: nothing is forced closed"; return 0; fi
  apps=$(list_apps)
  while IFS="$TAB" read -r name pid id; do
    [ -n "$name" ] || continue
    guard_awake
    kind=$(app_kind "$id")
    [ "$kind" = finder ] && continue
    if is_kept "$name" "$id"; then log "$name: kept (--keep); not ended"; continue; fi
    if [ "$DRY" = 1 ]; then
      if [ "$kind" = claude ]; then log "[dry run] would ask the Claude app to quit, then end it if it refuses, allowing ${CLAUDE_TERM_GRACE}s after TERM (this closes every Claude session)"
      else log "[dry run] would end $name if it is still open (unsaved changes in it are lost)"; fi
      continue
    fi
    if [ "$kind" = claude ]; then
      log "asking the Claude app to quit (it usually refuses while shutting down)"
      quit_app_async "$id" 25; nap 20
    fi
    if alive "$pid"; then
      if [ "$kind" = claude ]; then end_process "$pid" "$name" "$CLAUDE_TERM_GRACE"
      else end_process "$pid" "$name"; fi
    fi
  done <<EOF
$apps
EOF
}

phase_sleep() {
  if [ "$DRY" = 1 ]; then log "[dry run] last resort: would put the Mac to sleep (pmset sleepnow)"; return 0; fi
  log "--- step: LAST RESORT: the Mac would not shut down; putting it to sleep (pmset sleepnow)"
  pmset sleepnow >> "$LOG" 2>&1
  sleep 30
  log "awake again (this line is written after the Mac woke, or if the sleep was refused)"
}

worker() {
  LOG=$MS_LOG; DRY=$MS_DRY; ECHO=$MS_DRY; KEEP=$MS_KEEP; MS_LATE=${MS_LATE:-1800}
  trap on_term TERM INT
  rm -f "$SLEPT_MARK"
  if [ "$DRY" != 1 ]; then
    printf '%s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" > "$PID_FILE"
  fi
  log "=== mac-shutdown worker started (pid $$)$( [ "$DRY" = 1 ] && printf ' DRY RUN: nothing will be changed' ) ==="
  log "settings: force-close=$( [ "$MS_KILL" = 1 ] && echo yes || echo no) warning=${MS_WARN}s keep=[$(printf '%s' "${MS_KEEP#|}" | sed 's/|/, /g')]"
  phase_wait
  if [ -z "$MS_SAVE_DIR" ]; then   # named after the time the run starts (in a dry run, the planned start)
    if [ "$DRY" = 1 ]; then MS_SAVE_DIR="$SAVE_ROOT/$(date -r "$START_AT" '+%Y-%m-%d %H.%M')"
    else MS_SAVE_DIR="$SAVE_ROOT/$(date '+%Y-%m-%d %H.%M')"; fi
  fi
  log "never-saved drafts go to: $MS_SAVE_DIR"
  phase_warn;       guard_awake
  phase_engines;    guard_awake
  phase_save;       guard_awake
  phase_quit;       guard_awake
  phase_terminals;  guard_awake
  attempt_shutdown 1 && finish 0
  phase_force;      guard_awake
  attempt_shutdown 2 && finish 0
  phase_sleep
  finish 0
}

# ---------------------------------------------------------------- commands

parse_duration() {   # 90, 90s, 5m, 2h -> seconds
  printf '%s' "$1" | grep -qE '^[0-9]+[smh]?$' || die "bad duration: $1 (use 90s, 5m or 2h)"
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}

parse_at() {   # HH:MM or "YYYY-MM-DD HH:MM" -> epoch (the next HH:MM to come round)
  local t
  case "$1" in
    [0-9]:[0-5][0-9]|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9])
      t=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) $1:00" +%s) || die "bad time: $1"
      [ "$t" -le "$(now)" ] && t=$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) $1:00" +%s)
      echo "$t" ;;
    *)
      t=$(date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s 2>/dev/null) || die "bad time: $1 (use HH:MM or \"YYYY-MM-DD HH:MM\")"
      [ "$t" -gt "$(now)" ] || die "that time has already passed: $1"
      echo "$t" ;;
  esac
}

scheduled_pid() {   # prints the worker pid if one is alive
  local wpid
  [ -f "$PID_FILE" ] || return 1
  wpid=$(cut -d' ' -f1 "$PID_FILE")
  if [ -n "$wpid" ] && alive "$wpid" && ps -o command= -p "$wpid" | grep -q 'mac_shutdown'; then echo "$wpid"; return 0; fi
  return 1
}

OPT_LATE=1800 OPT_DELAY=120 OPT_AT="" OPT_AT_EPOCH="" OPT_AFTER_PID="" OPT_WARN=60 OPT_KILL=1 OPT_SAVE_DIR="" OPT_DRY=0 OPT_REPLACE=0
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --in) OPT_DELAY=$(parse_duration "${2:?--in needs a value}") || exit 2; shift ;;
      --at) OPT_AT="${2:?--at needs a value}"; shift ;;
      --after-pid) OPT_AFTER_PID="${2:?--after-pid needs a value}"; shift ;;
      --warn) OPT_WARN="${2:?--warn needs a value}"; shift ;;
      --keep) KEEP="$KEEP|${2:?--keep needs a value}"; shift ;;
      --no-kill) OPT_KILL=0 ;;
      --late-limit) OPT_LATE=$(parse_duration "${2:?--late-limit needs a value}") || exit 2; shift ;;
      --save-dir) OPT_SAVE_DIR="${2:?--save-dir needs a value}"; shift ;;
      --dry-run) OPT_DRY=1 ;;
      --replace) OPT_REPLACE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  case "$OPT_WARN" in *[!0-9]*|"") die "--warn needs a number of seconds" ;; esac
  case "$OPT_DELAY" in *[!0-9]*|"") die "--in gave no usable duration" ;; esac
  if [ -n "$OPT_AT" ]; then OPT_AT_EPOCH=$(parse_at "$OPT_AT") || exit 2; fi
  if [ -n "$OPT_AFTER_PID" ]; then
    case "$OPT_AFTER_PID" in *[!0-9]*) die "--after-pid needs a process id" ;; esac
    alive "$OPT_AFTER_PID" || say "note: process $OPT_AFTER_PID is not running, so there is nothing to wait for"
  fi
}

cmd_schedule() {
  parse_opts "$@"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  if [ "$OPT_DRY" = 0 ] && [ -f "$REHEARSAL_FILE" ]; then
    say "REHEARSAL MODE: $REHEARSAL_FILE exists, so this is a dry run and nothing will be changed."
    say "Delete that file for a real shutdown."
    OPT_DRY=1
  fi
  local existing stamp target
  if [ "$OPT_DRY" = 0 ] && existing=$(scheduled_pid); then
    if [ "$OPT_REPLACE" = 1 ]; then cmd_cancel; else
      say "A shutdown is already scheduled (worker $existing):"; cat "$INFO_FILE" 2>/dev/null
      die "cancel it first, or pass --replace"
    fi
  fi
  if [ -n "$OPT_AT" ]; then target=$OPT_AT_EPOCH; else target=$(( $(now) + OPT_DELAY )); fi
  case "$target" in ''|*[!0-9]*) die "could not work out the start time" ;; esac
  stamp=$(date +%Y%m%d-%H%M%S)
  export MS_TARGET=$target MS_DELAY=$OPT_DELAY MS_AFTER_PID=$OPT_AFTER_PID MS_WARN=$OPT_WARN MS_KILL=$OPT_KILL
  export MS_KEEP=$KEEP MS_DRY=$OPT_DRY MS_LATE=$OPT_LATE
  export MS_SAVE_DIR="$OPT_SAVE_DIR"   # empty: named when the run starts

  if [ "$OPT_DRY" = 1 ]; then
    export MS_LOG="$STATE_DIR/dryrun-$stamp.log"
    say "DRY RUN: nothing is scheduled. A real schedule with these settings would print:"
    schedule_summary "$target" "(none: dry run)" "$STATE_DIR/run-<date-time>.log" | sed 's/^/  | /'
    say ""
    say "Every step now runs read-only, in the foreground. Log: $MS_LOG"
    say ""
    worker
    exit 0
  fi

  export MS_LOG="$STATE_DIR/run-$stamp.log"
  : > "$MS_LOG"
  ln -sf "$MS_LOG" "$STATE_DIR/latest.log"
  rm -f "$CANCEL_MARK"
  # Detach: a new session (survives the Claude app closing), no hang-up, and no idle sleep while waiting.
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid() or warn "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' \
    /usr/bin/nohup /usr/bin/caffeinate -i /bin/bash "$SELF" _worker < /dev/null >> "$MS_LOG" 2>&1 &
  local i=0 wpid=""
  while [ $i -lt 10 ]; do
    sleep 1; i=$((i + 1))
    wpid=$(scheduled_pid) && break
  done
  [ -n "$wpid" ] || { cat "$MS_LOG"; die "the worker did not start; see the log above"; }
  schedule_summary "$target" "pid $wpid" "$MS_LOG" > "$INFO_FILE"
  cat "$INFO_FILE"
}

schedule_summary() {   # start epoch, worker text, log path
  local target=$1
  echo "Scheduled at:   $(fmt_time "$(now)")"
  if [ -n "$OPT_AFTER_PID" ]; then echo "Starts:         when process $OPT_AFTER_PID exits, plus $OPT_DELAY s (not before $(fmt_time "$target"))"
  else echo "Starts:         $(fmt_time "$target") (in $(( (target - $(now) + 59) / 60 )) min)"; fi
  echo "Warning:        $( [ "$OPT_WARN" -gt 0 ] && echo "${OPT_WARN}s on-screen warning with a Cancel button" || echo none)"
  echo "Force-close:    $( [ "$OPT_KILL" = 1 ] && echo "yes, apps that refuse to quit are ended" || echo "no; if refused, the Mac sleeps instead")"
  echo "Late limit:     $( [ "$OPT_LATE" -gt 0 ] && echo "skipped if it can only start more than $(( OPT_LATE / 60 )) min late (the Mac was asleep)" || echo "none")"
  if [ -n "$KEEP" ]; then echo "Never touched:  $(printf "%s" "${KEEP#|}" | sed "s/|/, /g")"; fi
  echo "Drafts folder:  ${OPT_SAVE_DIR:-$SAVE_ROOT/<date and time the run starts>}"
  echo "Log:            $3"
  echo "Worker:         $2"
  echo "Cancel:         \"$SELF\" cancel   (or click \"Cancel shutdown\" on the warning)"
}

cmd_cancel() {
  local wpid pgid
  if ! wpid=$(scheduled_pid); then
    rm -f "$PID_FILE" "$INFO_FILE"
    say "No shutdown is scheduled."
    return 0
  fi
  pgid=$(cut -d' ' -f2 "$PID_FILE")
  echo "cancelled with '$(basename "$SELF") cancel' at $(ts)" > "$CANCEL_MARK"
  if [ -n "$pgid" ] && [ "$pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]; then
    kill -s TERM -- "-$pgid" 2>/dev/null || kill -TERM "$wpid" 2>/dev/null
  else
    kill -TERM "$wpid" 2>/dev/null
  fi
  local i=0
  while alive "$wpid" && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
  if alive "$wpid"; then kill -KILL "$wpid" 2>/dev/null; sleep 1; fi
  rm -f "$PID_FILE" "$INFO_FILE"
  if alive "$wpid"; then die "worker $wpid is still running; end it with: kill -9 $wpid"; fi
  say "Cancelled the scheduled shutdown (worker $wpid)."
}

cmd_status() {
  local wpid
  if wpid=$(scheduled_pid); then
    say "A shutdown is scheduled:"
    cat "$INFO_FILE" 2>/dev/null
    say ""
    say "Log so far:"
    tail -n 5 "$(readlink "$STATE_DIR/latest.log" 2>/dev/null || echo "$STATE_DIR/latest.log")" 2>/dev/null
  else
    say "No shutdown is scheduled."
  fi
  [ -f "$REHEARSAL_FILE" ] && say "REHEARSAL MODE is on ($REHEARSAL_FILE): schedules are dry runs."
  return 0
}

cmd_last() {
  local f
  f=$(ls -t "$STATE_DIR"/run-*.log 2>/dev/null | head -n 1)
  if [ -z "$f" ]; then say "No shutdown has been run yet (no logs in $STATE_DIR)."
  else
    say "Latest run: $f"
    say "----"
    cat "$f"
    say "----"
  fi
  say "This Mac last started: $(sysctl -n kern.boottime | sed 's/^.*} //')"
  say "Recent shutdowns and starts, newest first:"
  last reboot 2>/dev/null | grep -E '^(reboot|shutdown)' | head -n 4 | sed 's/^/  /'
  return 0
}

cmd_preview() {
  parse_opts "$@"
  local apps name pid id kind out st dname detail users save_dir
  save_dir="${OPT_SAVE_DIR:-$SAVE_ROOT/<date and time of the run>}"
  say "PREVIEW (read-only; nothing is changed)"
  [ -f "$REHEARSAL_FILE" ] && say "!! REHEARSAL MODE is on ($REHEARSAL_FILE): schedules will be dry runs."
  if scheduled_pid >/dev/null; then say "!! A shutdown is already scheduled:"; sed 's/^/   /' "$INFO_FILE" 2>/dev/null; fi
  users=$(who | awk '{print $1}' | sort -u | paste -sd, -)
  say "Logged-in users: $users"
  case "$users" in *,*) say "!! More than one user is logged in: macOS asks for an admin password to shut down, so expect the sleep fallback." ;; esac
  say ""
  say "Open apps and what will happen to each:"
  apps=$(list_apps)
  [ -n "$apps" ] || say "  (could not list apps: System Events did not answer)"
  while IFS="$TAB" read -r name pid id; do
    [ -n "$name" ] || continue
    kind=$(app_kind "$id")
    if is_kept "$name" "$id"; then say "- $name: KEPT (--keep): never quit or ended. If it blocks the shutdown, the Mac sleeps instead."; continue; fi
    case "$kind" in
      finder) say "- $name: left to macOS." ;;
      claude) say "- $name: asked to quit last; if it refuses, it is ended. This closes EVERY Claude session in the app, so other sessions' unfinished work stops." ;;
      engine) say "- $name: stopped gracefully first (containers get their stop timeouts; restart policies are kept)." ;;
      terminal)
        say "- $name: asked to quit; $( [ "$OPT_KILL" = 1 ] && echo 'ended after 10 s if it refuses' || echo 'left open if it refuses (--no-kill)'). Running inside it now:"
        proc_tree "$pid" | sed 's/^/    /' ;;
      doc)
        out=$(run_docs "$id" list "$name" "$save_dir")
        if [ -z "$out" ]; then say "- $name: no open documents; asked to quit."; continue; fi
        say "- $name: unsaved work is saved first, then the app is asked to quit:"
        while IFS="$TAB" read -r st dname detail; do
          case "$st" in
            CLEAN) say "    \"$dname\": no unsaved changes" ;;
            UNSAVED) say "    \"$dname\": unsaved changes, saved in place ($detail)" ;;
            UNSAVED_NEW) say "    \"$dname\": never saved; will be saved as $detail" ;;
            ERROR) say "    could not check: $detail" ;;
            *) say "    $st $dname $detail" ;;
          esac
        done <<EOF
$out
EOF
        ;;
      other) say "- $name: asked to quit. If it asks about unsaved changes, it is $( [ "$OPT_KILL" = 1 ] && echo 'ended after the first shutdown attempt and those changes are LOST' || echo 'left open (--no-kill) and the Mac sleeps instead')." ;;
    esac
  done <<EOF
$apps
EOF
  say ""
  if docker_running; then
    say "Docker Desktop: running; stopped gracefully first."
    docker_notes preview | sed 's/^/  /'
  else say "Docker Desktop: not running."; fi
  local idle
  idle=$(pmset -g 2>/dev/null | awk '$1 == "sleep" { print $2; exit }')
  if [ -n "$idle" ] && [ "$idle" != 0 ]; then say "This Mac sleeps after $idle min idle; a scheduled run holds that off while it waits."; fi
  say "Drafts that were never saved go to: $save_dir"
  say "Logs go to: $STATE_DIR"
  say "If macOS still refuses after the apps are ended, the Mac is put to sleep instead."
}

# Tests source this file with MAC_SHUTDOWN_LIB=1 to load the functions without running a command.
if [ "${MAC_SHUTDOWN_LIB:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

case "${1:-help}" in
  preview) shift; cmd_preview "$@" ;;
  schedule) shift; cmd_schedule "$@" ;;
  cancel) cmd_cancel ;;
  status) cmd_status ;;
  last) cmd_last ;;
  _worker) worker ;;
  _docs) shift; run_docs "$@" ;;   # testing: _docs <bundle id> list|save <app name> <dir> [only this document]
  _warn) MS_WARN="${2:-5}"; phase_warn; echo "(the warning returned; a real run would carry on)" ;;   # testing
  help|-h|--help) usage ;;
  *) die "unknown command: $1 (preview, schedule, cancel, status, last)" ;;
esac

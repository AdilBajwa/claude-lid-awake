#!/bin/bash
# lid-awake: keep the Mac awake — lid closed included — while Claude Code
# sessions (terminal CLI and the desktop app's Code tab) are working.
#
# Every Claude Code hook event calls `lid-awake.sh hook` with the event JSON on
# stdin. Each session gets its own files under sessions/ (no shared JSON to
# race on). A watchdog holds `pmset disablesleep 1` while any session needs it
# and puts normal sleep back as soon as none do, then exits.
#
# Commands: hook | status | history | off | check | watchdog
#   status  key=value lines (read by the menu bar app)
#   history the newest lid closures, newest first (read by the menu bar app)
#   off     let the Mac sleep now; stays off until your next prompt
#   check   one-shot failsafe pass (run by the LaunchAgent every 5 min)

set -u

DIR="${LID_AWAKE_DIR:-$HOME/.claude/lid-awake}"
SELF="$DIR/lid-awake.sh"
SESSIONS="$DIR/sessions"
HANDOFFS="$DIR/handoffs"
RUNS="$DIR/runs"
CLOSURES="$DIR/closures"
CLOSURE="$DIR/closure"               # start time of the closure in progress
PIDFILE="$DIR/watchdog.pid"
MARKER="$DIR/sleep-disabled-by-us"   # only undo what we did ourselves
PAUSED="$DIR/paused"                 # "Let Mac sleep now", cleared by the next prompt
LOG="$DIR/lid-awake.log"

CAP_SEC="${LID_AWAKE_CAP_SEC:-14400}"         # 4h of lid-closed time per task, per closure
SILENCE_SEC="${LID_AWAKE_SILENCE_SEC:-14400}" # 4h with no hook = stuck or crashed
WAIT_SEC="${LID_AWAKE_WAIT_SEC:-600}"         # 10 min awake while waiting on you
IDLE_SEC="${LID_AWAKE_IDLE_SEC:-300}"         # 5 min awake after a turn finishes
HANDOFF_SEC="${LID_AWAKE_HANDOFF_SEC:-120}"   # time to write the handoff before sleeping
MIN_BATTERY="${LID_AWAKE_MIN_BATTERY:-10}"    # let it sleep at 10% or lower
POLL_SEC="${LID_AWAKE_POLL_SEC:-20}"
PMSET="${LID_AWAKE_PMSET:-sudo -n /usr/bin/pmset -a disablesleep}"

HANDOFF_TAG="LID-AWAKE HANDOFF"
HANDOFF_ASK="lid-awake: this task has used its 4-hour lid-closed limit, so tools are now disabled and the Mac will be allowed to sleep. Do not start any new work. Reply now with a handoff note so the task can be resumed exactly later. Start the reply with the line '$HANDOFF_TAG' and include: 1) the user's goal, 2) what is done, marking what was verified and what was not, 3) the step that was in progress and its exact state, 4) the exact next step, 5) files changed, 6) any command or process that may still be running. Use only facts from this session; write 'unknown' rather than guess."

mkdir -p "$SESSIONS" "$HANDOFFS" "$RUNS" "$CLOSURES"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
now() { date +%s; }
mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
kv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n1; }

lid_state() {
  if [ -n "${LID_AWAKE_FAKE_LID:-}" ]; then echo "$LID_AWAKE_FAKE_LID"; return; fi
  ioreg -r -k AppleClamshellState -d 4 | grep -q '"AppleClamshellState" = Yes' && echo closed || echo open
}

# Prints "<ac|battery> <percent>"
power_state() {
  if [ -n "${LID_AWAKE_FAKE_BATT:-}" ]; then
    [ "$LID_AWAKE_FAKE_BATT" = ac ] && echo "ac 100" || echo "battery $LID_AWAKE_FAKE_BATT"
    return
  fi
  local b pct
  b=$(pmset -g batt)
  pct=$(grep -Eo '[0-9]+%' <<<"$b" | head -n1 | tr -d %)
  if grep -q "AC Power" <<<"$b"; then echo "ac ${pct:-100}"; else echo "battery ${pct:-100}"; fi
}

battery_ok() {
  local src pct
  read -r src pct <<<"$(power_state)"
  [ "$src" = ac ] || [ "$pct" -gt "$MIN_BATTERY" ]
}

sleep_disabled_now() {
  # Dry-run (fake pmset): never read the real Mac's setting.
  if [ -n "${LID_AWAKE_PMSET:-}" ]; then [ -f "$MARKER" ] && echo 1 || echo 0; return; fi
  pmset -g | awk '/SleepDisabled/ {print $2}'
}

hold_warned=0
hold() {
  [ -f "$MARKER" ] && return
  # Already disabled by the user themselves: leave it, and don't take ownership.
  [ "$(sleep_disabled_now)" = 1 ] && return
  if $PMSET 1 >/dev/null 2>>"$LOG"; then
    touch "$MARKER"; hold_warned=0
    log "sleep disabled"
  elif [ "$hold_warned" = 0 ]; then
    hold_warned=1
    log "could not disable sleep: is the sudo rule installed? (run install.sh)"
  fi
}

release() {
  [ -f "$MARKER" ] || return
  if $PMSET 0 >/dev/null 2>>"$LOG"; then
    rm -f "$MARKER"; log "sleep restored"
  else
    log "could not restore sleep; run: sudo pmset -a disablesleep 0"
  fi
}

# False with an external display in use: a closed lid doesn't sleep the Mac then.
clamshell_sleeps() {
  if [ -n "${LID_AWAKE_FAKE_CLAMSHELL_SLEEP:-}" ]; then [ "$LID_AWAKE_FAKE_CLAMSHELL_SLEEP" = yes ]; return; fi
  ioreg -r -k AppleClamshellCausesSleep -d 4 | grep -q '"AppleClamshellCausesSleep" = Yes'
}

# macOS only sleeps at the moment the lid closes, so a lid closed during a
# hold stays awake after release until something asks it to sleep.
release_and_sleep() {
  [ -f "$MARKER" ] || return
  release
  [ -f "$MARKER" ] && return
  [ "$(lid_state)" = closed ] && clamshell_sleeps || return
  log "lid is closed, asking the Mac to sleep"
  # Dry-run (fake pmset): never sleep the real Mac.
  [ -n "${LID_AWAKE_PMSET:-}" ] && return
  /usr/bin/pmset sleepnow >/dev/null 2>>"$LOG"
}

# ── Session state ──────────────────────────────────────────────────────────────
# sessions/<id>.state  hook-owned: state=working|waiting|idle|stopped, since, turn, cwd
# sessions/<id>.lid    watchdog-owned: "<turn> <lid-closed seconds> <closure> <seconds in that closure>"
# sessions/<id>.stop   watchdog-owned: the 4h limit was hit this turn

set_state() { # <sid> <state> [new-turn]
  local f="$SESSIONS/$1.state" old since turn cwd t
  t=$(now)
  old=$(kv state "$f"); since=$(kv since "$f"); turn=$(kv turn "$f"); cwd=$(kv cwd "$f")
  [ "$old" = "$2" ] || since=$t
  [ -n "${3:-}" ] && turn=$t
  [ -n "$hook_cwd" ] && cwd=$hook_cwd
  printf 'state=%s\nsince=%s\nturn=%s\ncwd=%s\n' "$2" "${since:-$t}" "${turn:-$t}" "$cwd" > "$f.tmp"
  mv "$f.tmp" "$f"
}

lid_read() { # <sid> -> sets l_secs, l_closure, l_csecs for the current turn
  local turn t s c cs
  turn=$(kv turn "$SESSIONS/$1.state")
  read -r t s c cs <<<"$(cat "$SESSIONS/$1.lid" 2>/dev/null)"
  l_secs=0; l_closure=""; l_csecs=0
  [ "${t:-}" = "$turn" ] || return 0
  l_secs=${s:-0}; l_closure=${c:-}; l_csecs=${cs:-0}
}

# ── Lid closures ─────────────────────────────────────────────────────────
# closures/<start>  start=, then task=<secs>|<result>|<sid>|<cwd> lines, and
#                   end= and awake= once the lid opens. Closures where nothing
#                   held the Mac awake aren't kept.

closure_task() { # <closure> <secs> <result> <sid>
  printf 'task=%s|%s|%s|%s\n' "$2" "$3" "$4" "$(kv cwd "$SESSIONS/$4.state")" >> "$CLOSURES/$1"
}

end_closure() {
  local claim="$CLOSURE.$$" id awake f sid
  # mv is atomic: if the watchdog and a status call race, only one ends it.
  mv "$CLOSURE" "$claim" 2>/dev/null || return
  id=$(cat "$claim"); rm -f "$claim"
  awake=$(cat "$CLOSURE.awake" 2>/dev/null || echo 0); rm -f "$CLOSURE.awake"
  for f in "$SESSIONS"/*.lid; do
    [ -e "$f" ] || continue
    sid=$(basename "$f" .lid)
    lid_read "$sid"
    if [ "$l_closure" = "$id" ] && [ "$l_csecs" -gt 0 ]; then
      if [ -f "$SESSIONS/$sid.stop" ]; then closure_task "$id" "$l_csecs" stopped "$sid"
      else closure_task "$id" "$l_csecs" running "$sid"; fi
    fi
  done
  if [ "$awake" = 0 ] && ! grep -q '^task=' "$CLOSURES/$id" 2>/dev/null; then
    rm -f "$CLOSURES/$id"
    return
  fi
  printf 'end=%s\nawake=%s\n' "$(now)" "$awake" >> "$CLOSURES/$id"
  log "lid opened: closed for $(( $(now) - id ))s, awake for ${awake}s"
}

track_closure() { # <lid state>
  local t
  if [ "$1" = closed ]; then
    [ -f "$CLOSURE" ] && return
    t=$(now)
    ( set -C; echo "$t" > "$CLOSURE" ) 2>/dev/null || return
    rm -f "$CLOSURE.awake"
    echo "start=$t" > "$CLOSURES/$t"
  else
    end_closure
  fi
}

watchdog_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

claim_watchdog() {
  ( set -C; echo $$ > "$PIDFILE" ) 2>/dev/null && return 0
  watchdog_running && return 1
  rm -f "$PIDFILE"
  ( set -C; echo $$ > "$PIDFILE" ) 2>/dev/null
}

start_watchdog() {
  watchdog_running && return
  nohup /bin/bash "$SELF" watchdog </dev/null >/dev/null 2>&1 &
}

# One pass over all sessions. Sets: needs_hold, n_working, n_waiting,
# wait_left, idle_left, max_lid. Notices the lid opening or closing. With $1 = <seconds
# since last tick> and the lid closed, also adds lid-closed time and marks
# sessions that hit the limit.
scan() {
  local dt="${1:-0}" lid t f sid state age since turn left closure_id
  lid=$(lid_state); t=$(now)
  track_closure "$lid"
  closure_id=$(cat "$CLOSURE" 2>/dev/null)
  needs_hold=0; n_working=0; n_waiting=0; wait_left=""; idle_left=0; max_lid=0
  for f in "$SESSIONS"/*.state; do
    [ -e "$f" ] || continue
    sid=$(basename "$f" .state)
    age=$(( t - $(mtime "$f") ))
    if [ "$age" -gt "$SILENCE_SEC" ]; then
      rm -f "$SESSIONS/$sid".*
      log "session $sid: no activity for $SILENCE_SEC s, dropped"
      continue
    fi
    state=$(kv state "$f")
    case "$state" in
      working)
        if [ -f "$SESSIONS/$sid.stop" ]; then
          [ $(( t - $(mtime "$SESSIONS/$sid.stop") )) -lt "$HANDOFF_SEC" ] && needs_hold=1
          continue
        fi
        n_working=$((n_working + 1)); needs_hold=1
        lid_read "$sid"
        # Reclosing the lid starts the limit again.
        [ "$l_closure" = "$closure_id" ] || l_csecs=0
        if [ "$lid" = closed ] && [ "$dt" -gt 0 ]; then
          l_secs=$((l_secs + dt)); l_csecs=$((l_csecs + dt)); turn=$(kv turn "$f")
          echo "$turn $l_secs $closure_id $l_csecs" > "$SESSIONS/$sid.lid"
          if [ "$l_csecs" -ge "$CAP_SEC" ]; then
            touch "$SESSIONS/$sid.stop"
            log "session $sid: lid-closed limit reached, asking for a handoff"
          fi
        fi
        [ "$l_csecs" -gt "$max_lid" ] && max_lid=$l_csecs
        ;;
      waiting)
        since=$(kv since "$f"); left=$(( WAIT_SEC - (t - since) ))
        if [ "$left" -gt 0 ]; then
          n_waiting=$((n_waiting + 1)); needs_hold=1
          { [ -z "$wait_left" ] || [ "$left" -gt "$wait_left" ]; } && wait_left=$left
        fi
        ;;
      idle)
        since=$(kv since "$f"); left=$(( IDLE_SEC - (t - since) ))
        if [ "$left" -gt 0 ]; then
          needs_hold=1
          [ "$left" -gt "$idle_left" ] && idle_left=$left
        fi
        ;;
    esac
  done
  if [ "$lid" = closed ] && [ "$dt" -gt 0 ] && [ "$needs_hold" = 1 ]; then
    echo $(( $(cat "$CLOSURE.awake" 2>/dev/null || echo 0) + dt )) > "$CLOSURE.awake"
  fi
}

watchdog() {
  claim_watchdog || exit 0
  trap 'release; rm -f "$PIDFILE"; exit 0' TERM INT HUP
  local last t dt low_logged=0
  last=$(now)
  while :; do
    t=$(now); dt=$((t - last)); last=$t
    # A long gap means the Mac was asleep; don't count that as lid-closed work.
    [ "$dt" -gt $((POLL_SEC * 3)) ] && dt=0
    if [ -f "$PAUSED" ]; then release; break; fi
    scan "$dt"
    if [ "$needs_hold" = 0 ]; then release_and_sleep; break; fi
    if battery_ok; then
      low_logged=0; hold
    else
      [ "$low_logged" = 0 ] && log "battery at or below ${MIN_BATTERY}%, letting the Mac sleep"
      low_logged=1; release_and_sleep
    fi
    sleep "$POLL_SEC"
  done
  rm -f "$PIDFILE"
}

# ── Hook handling ──────────────────────────────────────────────────────────────
# Prints nothing except the JSON replies Claude Code acts on.

finish_turn() { # Stop: <sid>
  local sid=$1 result=completed msg secs t
  if [ -f "$SESSIONS/$sid.stop" ]; then
    result=stopped
    msg=$(j last_assistant_message)
    if grep -q "$HANDOFF_TAG" <<<"$msg"; then
      printf '%s\n' "$msg" > "$HANDOFFS/$sid.md"
    elif [ "$(j stop_hook_active)" != true ]; then
      printf '{"decision":"block","reason":"%s"}\n' "$HANDOFF_ASK"
      return
    fi
  fi
  lid_read "$sid"
  secs=$l_secs
  # A task still going when the lid opened was already recorded by end_closure.
  if [ -n "$l_closure" ] && [ "$l_closure" = "$(cat "$CLOSURE" 2>/dev/null)" ] && [ "$l_csecs" -gt 0 ]; then
    closure_task "$l_closure" "$l_csecs" "$result" "$sid"
  fi
  if [ "$secs" -gt 0 ]; then
    t=$(now)
    {
      echo "result=$result"
      echo "ended=$t"
      echo "session=$sid"
      echo "cwd=$(kv cwd "$SESSIONS/$sid.state")"
      echo "lid_secs=$secs"
      [ -f "$HANDOFFS/$sid.md" ] && [ "$result" = stopped ] && echo "handoff=$HANDOFFS/$sid.md"
    } > "$RUNS/$t-$sid"
    log "session $sid: lid-closed run $result after ${secs}s lid-closed"
  fi
  rm -f "$SESSIONS/$sid.stop" "$SESSIONS/$sid.lid"
  # A task stopped at the limit has had its time, so it gets no idle wait.
  if [ "$result" = stopped ]; then set_state "$sid" stopped; else set_state "$sid" idle; fi
}

hook() {
  input=$(cat)
  j() { plutil -extract "$1" raw -o - - <<<"$input" 2>/dev/null; }
  local sid event tool
  sid=$(j session_id | tr -cd 'A-Za-z0-9._-'); sid=${sid:-default}
  event=$(j hook_event_name)
  hook_cwd=$(j cwd)
  case "$event" in
    UserPromptSubmit)
      rm -f "$PAUSED" "$SESSIONS/$sid.stop" "$SESSIONS/$sid.lid"
      set_state "$sid" working new-turn
      start_watchdog
      ;;
    PreToolUse)
      if [ -f "$SESSIONS/$sid.stop" ]; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$HANDOFF_ASK"
        return
      fi
      tool=$(j tool_name)
      case "$tool" in
        AskUserQuestion|ExitPlanMode) set_state "$sid" waiting ;;
        *) set_state "$sid" working ;;
      esac
      start_watchdog
      ;;
    PostToolUse)
      if [ -f "$SESSIONS/$sid.stop" ]; then
        printf '{"decision":"block","reason":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$HANDOFF_ASK" "$HANDOFF_ASK"
        return
      fi
      set_state "$sid" working
      start_watchdog
      ;;
    PermissionRequest)
      set_state "$sid" waiting
      start_watchdog
      ;;
    Notification)
      case "$(j notification_type)" in
        permission_prompt|elicitation_dialog|agent_needs_input)
          set_state "$sid" waiting
          start_watchdog
          ;;
      esac
      ;;
    Stop)
      finish_turn "$sid"
      ;;
    SessionEnd)
      rm -f "$SESSIONS/$sid".*
      ;;
  esac
}

# ── Commands ───────────────────────────────────────────────────────────────────

hook_cwd=""
case "${1:-}" in
  hook)
    hook
    ;;
  watchdog)
    watchdog
    ;;
  check)
    scan 0
    if [ "$needs_hold" = 1 ] && [ ! -f "$PAUSED" ]; then start_watchdog
    elif ! watchdog_running; then release_and_sleep
    fi
    ;;
  off)
    touch "$PAUSED"
    watchdog_running && kill "$(cat "$PIDFILE")"
    release
    echo "Normal sleep restored until your next prompt."
    ;;
  status)
    scan 0
    read -r src pct <<<"$(power_state)"
    echo "holding=$([ -f "$MARKER" ] && echo 1 || echo 0)"
    echo "paused=$([ -f "$PAUSED" ] && echo 1 || echo 0)"
    echo "working=$n_working"
    echo "waiting=$n_waiting"
    echo "wait_left=${wait_left:-0}"
    echo "idle_left=$idle_left"
    echo "lid=$(lid_state)"
    echo "lid_used=$max_lid"
    echo "cap=$CAP_SEC"
    echo "power=$src"
    echo "battery=$pct"
    echo "min_battery=$MIN_BATTERY"
    echo "watchdog=$(watchdog_running && echo running || echo stopped)"
    echo "sleep_disabled=$(sleep_disabled_now)"
    # `sudo -l <cmd>` succeeds for any admin (password or not), so look for the
    # NOPASSWD rule itself; tr undoes sudo's line wrapping.
    echo "sudo=$(sudo -n -l 2>/dev/null | tr -s ' \n' ' ' | grep -q 'NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' && echo ok || echo missing)"
    echo "log=$LOG"
    last=$(ls -t "$RUNS" 2>/dev/null | head -n1)
    [ -n "$last" ] && sed 's/^/last_/' "$RUNS/$last"
    ;;
  history)
    scan 0
    for f in $(ls -r "$CLOSURES" | head -n 50); do cat "$CLOSURES/$f"; done
    ;;
  *)
    echo "usage: $0 hook|status|history|off|check" >&2
    ;;
esac
exit 0

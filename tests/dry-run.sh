#!/bin/bash
# Dry-run tests: fake hook events, fake lid, fake battery, fake pmset.
# Never touches the real sleep setting. Run: bash tests/dry-run.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'pkill -f "$T/lid-awake.sh watchdog" 2>/dev/null; rm -rf "$T"' EXIT
cp "$ROOT/lid-awake.sh" "$T/"

export LID_AWAKE_DIR="$T" LID_AWAKE_PMSET="echo FAKE" LID_AWAKE_POLL_SEC=1
export LID_AWAKE_CAP_SEC=3 LID_AWAKE_WAIT_SEC=3 LID_AWAKE_SILENCE_SEC=3600 LID_AWAKE_HANDOFF_SEC=1 LID_AWAKE_IDLE_SEC=0
export LID_AWAKE_FAKE_LID=open LID_AWAKE_FAKE_BATT=ac LID_AWAKE_FAKE_CLAMSHELL_SLEEP=yes
S="$T/lid-awake.sh"
pass=0; fail=0

ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
ev()   { echo "{\"session_id\":\"$1\",\"hook_event_name\":\"$2\",\"cwd\":\"/tmp/proj\"${3:-}}" | "$S" hook; }
holding() { [ -f "$T/sleep-disabled-by-us" ]; }
st()   { "$S" status | sed -n "s/^$1=//p"; }
valid_json() { python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$1"; }
wait_for() { local i; for i in $(seq 1 "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }

echo "working holds the Mac awake; hooks are silent"
out=$(ev A UserPromptSubmit; ev A PreToolUse ',"tool_name":"Bash"')
check "hooks print nothing" '[ -z "$out" ]'
check "holds within 3s" 'wait_for holding 3'
check "status shows 1 working" '[ "$(st working)" = 1 ]'

echo "waiting on a permission holds for WAIT_SEC, then lets go"
ev A PermissionRequest ',"tool_name":"Bash"'
check "waiting counted" '[ "$(st waiting)" = 1 ]'
check "still holding while waiting" 'holding'
check "released after the wait window" 'wait_for "! holding" 6'
check "watchdog exited" 'wait_for "[ \"\$(st watchdog)\" = stopped ]" 3'
ev A PostToolUse ',"tool_name":"Bash"'
check "approval (PostToolUse) holds again" 'wait_for holding 3'

echo "AskUserQuestion counts as waiting; idle_prompt notification is ignored"
ev A PreToolUse ',"tool_name":"AskUserQuestion"'
check "AskUserQuestion -> waiting" '[ "$(st waiting)" = 1 ]'
ev A PostToolUse ',"tool_name":"AskUserQuestion"'
ev A Notification ',"notification_type":"idle_prompt"'
check "idle_prompt leaves it working" '[ "$(st working)" = 1 ]'
ev A Notification ',"notification_type":"permission_prompt"'
check "permission_prompt -> waiting" '[ "$(st waiting)" = 1 ]'
ev A PostToolUse ',"tool_name":"Bash"'

echo "Stop releases"
ev A Stop
check "released after Stop" 'wait_for "! holding" 3'
check "no lid-closed run recorded (lid was open)" '[ -z "$(ls "$T/runs")" ]'

echo "battery"
export LID_AWAKE_FAKE_BATT=10
ev B UserPromptSubmit
sleep 2
check "no hold at 10% on battery" '! holding'
export LID_AWAKE_FAKE_BATT=11
pkill -f "$T/lid-awake.sh watchdog"; sleep 1
ev B PreToolUse ',"tool_name":"Bash"'
check "holds at 11% on battery" 'wait_for holding 3'
ev B Stop; wait_for "! holding" 3
export LID_AWAKE_FAKE_BATT=ac

echo "lid-open time doesn't count"
ev C UserPromptSubmit
sleep 4
check "lid open: no limit after 4s" '[ ! -f "$T/sessions/C.stop" ]'
ev C Stop; wait_for "! holding" 3; pkill -f "$T/lid-awake.sh watchdog"; sleep 1

echo "lid closed, limit hit -> tools denied, handoff, release"
export LID_AWAKE_FAKE_LID=closed
ev D UserPromptSubmit
check "limit reached after ~3s lid-closed" 'wait_for "[ -f \"$T/sessions/D.stop\" ]" 8'
check "released once the only task hit the limit" 'wait_for "! holding" 3'
out=$(ev D PreToolUse ',"tool_name":"Bash"')
check "PreToolUse denied" 'grep -q "\"permissionDecision\":\"deny\"" <<<"$out"'
check "deny reply is valid JSON" 'valid_json "$out"'
out=$(ev D PostToolUse ',"tool_name":"Bash"')
check "PostToolUse blocked with reason" 'grep -q "\"decision\":\"block\"" <<<"$out" && valid_json "$out"'
out=$(ev D Stop ',"stop_hook_active":false,"last_assistant_message":"I will stop."')
check "Stop without handoff is sent back once" 'grep -q "\"decision\":\"block\"" <<<"$out" && valid_json "$out"'
out=$(ev D Stop ',"stop_hook_active":true,"last_assistant_message":"LID-AWAKE HANDOFF\n1) goal: x\n4) next: y"')
check "Stop with handoff ends quietly" '[ -z "$out" ]'
check "handoff saved" 'grep -q "LID-AWAKE HANDOFF" "$T/handoffs/D.md"'
check "run recorded as stopped" '[ "$(st last_result)" = stopped ] && [ -n "$(st last_handoff)" ]'
check "session idle, nothing working" '[ "$(st working)" = 0 ]'

echo "lid-closed task that finishes in time is recorded as completed"
export LID_AWAKE_CAP_SEC=3600
pkill -f "$T/lid-awake.sh watchdog"; sleep 1
ev E UserPromptSubmit
sleep 3
ev E Stop
check "run recorded as completed" '[ "$(st last_result)" = completed ] && [ -z "$(st last_handoff)" ]'
check "lid seconds recorded" '[ "$(st last_lid_secs)" -ge 1 ]'

echo "a session silent past SILENCE_SEC is dropped"
pkill -f "$T/lid-awake.sh watchdog"; sleep 1
ev F UserPromptSubmit
touch -t "$(date -v-2H +%Y%m%d%H%M)" "$T/sessions/F.state"
LID_AWAKE_SILENCE_SEC=3600 "$S" check
check "stale session removed" '[ ! -f "$T/sessions/F.state" ]'

echo "'Let Mac sleep now' pauses until the next prompt"
ev G UserPromptSubmit
wait_for holding 3
"$S" off >/dev/null
check "released by off" '! holding'
ev G PreToolUse ',"tool_name":"Bash"'
sleep 2
check "tool calls don't re-hold while paused" '! holding'
ev G UserPromptSubmit
check "next prompt holds again" 'wait_for holding 3'
ev G SessionEnd

echo "closures are recorded; reclosing the lid restarts the limit"
pkill -f "$T/lid-awake.sh watchdog"; sleep 1
export LID_AWAKE_FAKE_LID=open; "$S" status >/dev/null
rm -f "$T"/closures/*
export LID_AWAKE_FAKE_LID=closed; "$S" status >/dev/null
export LID_AWAKE_FAKE_LID=open; "$S" status >/dev/null
check "closure with nothing held awake isn't kept" '[ -z "$(ls "$T/closures")" ]'
export LID_AWAKE_CAP_SEC=5 LID_AWAKE_FAKE_LID=closed
ev J UserPromptSubmit
sleep 3
check "no end time while closed" '! "$S" history | grep -q "^end="'
pkill -f "$T/lid-awake.sh watchdog"; sleep 1
export LID_AWAKE_FAKE_LID=open
out=$("$S" history)
check "opening records the end and awake time" 'grep -q "^end=" <<<"$out" && [ "$(sed -n "s/^awake=//p" <<<"$out")" -ge 1 ]'
check "task still working is recorded" 'grep -q "^task=[0-9]*|running|J|/tmp/proj$" <<<"$out"'
check "timer shows 0 with the lid open" '[ "$(st lid_used)" = 0 ]'
export LID_AWAKE_FAKE_LID=closed
ev J PreToolUse ',"tool_name":"Bash"'
sleep 3
check "reclosing restarts the limit (6s total, limit 5s)" '[ ! -f "$T/sessions/J.stop" ]'
check "timer shows only this closure" '[ "$(st lid_used)" -lt 5 ]'
check "limit still applies to the new closure" 'wait_for "[ -f \"\$T/sessions/J.stop\" ]" 6'
ev J Stop ',"stop_hook_active":true,"last_assistant_message":"LID-AWAKE HANDOFF\nx"' >/dev/null
check "run keeps total lid-closed time across closures" '[ "$(st last_lid_secs)" -ge 6 ]'
check "ending in a closure records the result there" '"$S" history | grep -q "^task=[0-9]*|stopped|J|"'
check "second closure is listed first" '[ "$("$S" history | sed -n 1p)" = "start=$(ls -r "$T/closures" | head -n1)" ]'
ev J SessionEnd
# The watchdog keeps the closed fake lid it started with, so stop it first.
pkill -f "$T/lid-awake.sh watchdog"; sleep 1
export LID_AWAKE_FAKE_LID=open LID_AWAKE_CAP_SEC=3600; "$S" status >/dev/null
check "two closures in history" '[ "$("$S" history | grep -c "^start=")" = 2 ] && [ "$("$S" history | grep -c "^end=")" = 2 ]'

echo "releasing with the lid closed asks the Mac to sleep"
asked() { grep -qs "asking the Mac to sleep" "$T/lid-awake.log"; }
fresh() { pkill -f "$T/lid-awake.sh watchdog"; sleep 1; rm -f "$T"/sessions/* "$T/sleep-disabled-by-us" "$T/lid-awake.log"; }
fresh; export LID_AWAKE_FAKE_LID=closed
ev K UserPromptSubmit; wait_for holding 3
check "no sleep request while working" '! asked'
ev L UserPromptSubmit; ev K Stop; sleep 2
check "no sleep request while another session works" 'holding && ! asked'
ev L Stop
check "turn finished, lid closed: sleep requested" 'wait_for asked 3 && ! holding'
fresh
ev K UserPromptSubmit; wait_for holding 3
ev K PermissionRequest ',"tool_name":"Bash"'
sleep 1
check "no sleep request during the wait window" 'holding && ! asked'
check "wait window over, lid closed: sleep requested" 'wait_for asked 6'
fresh; export LID_AWAKE_HANDOFF_SEC=60 LID_AWAKE_CAP_SEC=1
ev K UserPromptSubmit
wait_for "[ -f \"\$T/sessions/K.stop\" ]" 5; sleep 2
check "limit hit: stays awake to write the handoff" 'holding && ! asked'
ev K Stop ',"stop_hook_active":true,"last_assistant_message":"LID-AWAKE HANDOFF\nx"' >/dev/null
check "handoff written: sleep requested" 'wait_for asked 3'
fresh
touch "$T/sleep-disabled-by-us"
ev K UserPromptSubmit; touch -t "$(date -v-2M +%Y%m%d%H%M)" "$T/sessions/K.stop"
check "no handoff within the time allowed: sleep requested" 'wait_for asked 4'
export LID_AWAKE_HANDOFF_SEC=1 LID_AWAKE_CAP_SEC=3600
fresh; export LID_AWAKE_FAKE_LID=open
ev K UserPromptSubmit; wait_for holding 3; ev K Stop
check "lid open: released without a sleep request" 'wait_for "! holding" 3 && ! asked'
fresh; export LID_AWAKE_FAKE_LID=closed LID_AWAKE_FAKE_CLAMSHELL_SLEEP=no
ev K UserPromptSubmit; wait_for holding 3; ev K Stop
check "external display: released without a sleep request" 'wait_for "! holding" 3 && ! asked'
export LID_AWAKE_FAKE_CLAMSHELL_SLEEP=yes
fresh; export LID_AWAKE_FAKE_BATT=10
ev K UserPromptSubmit; sleep 2; ev K Stop; sleep 2
check "never held by us: no sleep request" '! asked'
fresh
touch "$T/sleep-disabled-by-us"
ev K UserPromptSubmit
check "battery low while holding: sleep requested" 'wait_for asked 3'
export LID_AWAKE_FAKE_BATT=ac
fresh
touch "$T/sleep-disabled-by-us"; rm -f "$T/watchdog.pid"
"$S" check
check "failsafe restores sleep and requests it" 'asked && ! holding'
ev K SessionEnd
fresh

echo "stays awake for IDLE_SEC after a turn finishes"
export LID_AWAKE_IDLE_SEC=4
ev K UserPromptSubmit; wait_for holding 3; ev K Stop; sleep 2
check "still holding during the idle wait" 'holding && ! asked'
check "idle time left is shown" '[ "$(st idle_left)" -gt 0 ] && [ "$(st working)" = 0 ]'
check "idle wait over, lid closed: sleep requested" 'wait_for asked 5 && ! holding'
fresh
ev K UserPromptSubmit; wait_for holding 3; ev K Stop; sleep 2
ev K UserPromptSubmit; sleep 4
check "new prompt during the idle wait keeps holding" 'holding && ! asked'
fresh; export LID_AWAKE_CAP_SEC=1 LID_AWAKE_HANDOFF_SEC=60 LID_AWAKE_IDLE_SEC=60
ev K UserPromptSubmit
wait_for "[ -f \"\$T/sessions/K.stop\" ]" 5
ev K Stop ',"stop_hook_active":true,"last_assistant_message":"LID-AWAKE HANDOFF\nx"' >/dev/null
check "stopped at the limit: no idle wait" 'wait_for asked 3'
export LID_AWAKE_CAP_SEC=3600 LID_AWAKE_HANDOFF_SEC=1 LID_AWAKE_IDLE_SEC=0
ev K SessionEnd
fresh; export LID_AWAKE_FAKE_LID=open; "$S" status >/dev/null

echo "Failsafe: marker left by a crash is cleaned up by check"
pkill -f "$T/lid-awake.sh watchdog"; sleep 1
touch "$T/sleep-disabled-by-us"; rm -f "$T/watchdog.pid"
"$S" check
check "check restores sleep" '! holding'

echo "Speed: one hook call"
start=$(python3 -c 'import time;print(time.time())')
ev H PreToolUse ',"tool_name":"Bash"'
ms=$(python3 -c "import time;print(int((time.time()-$start)*1000))")
check "hook takes under 200 ms (took ${ms} ms)" '[ "$ms" -lt 200 ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

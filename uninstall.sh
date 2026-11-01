#!/bin/bash
# Removes everything install.sh added and restores normal sleep.
# Leaves ~/.claude/lid-awake/handoffs, runs and closures in place.
set -uo pipefail

DIR="$HOME/.claude/lid-awake"
SETTINGS="$HOME/.claude/settings.json"
AGENTS="$HOME/Library/LaunchAgents"

"$DIR/lid-awake.sh" off

/usr/bin/python3 -I - "$SETTINGS" <<'EOF'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path))
hooks = s.get('hooks', {})
for ev in list(hooks):
    hooks[ev] = [e for e in hooks[ev]
                 if not any('lid-awake.sh' in h.get('command', '') for h in e.get('hooks', []))]
    if not hooks[ev]: del hooks[ev]
if not hooks: s.pop('hooks', None)
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(s, f, indent=2); f.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, path)
EOF

for name in claude-lid-awake claude-lid-awake-menu; do
  launchctl bootout "gui/$(id -u)" "$AGENTS/com.$USER.$name.plist" 2>/dev/null
  rm -f "$AGENTS/com.$USER.$name.plist"
done
rm -f "$DIR/LidAwakeMenu" "$DIR/lid-awake.sh" "$DIR/paused" "$DIR/resume.command" "$DIR/closure" "$DIR/closure.awake"
sudo rm -f /etc/sudoers.d/claude-lid-awake
echo "lid-awake removed. Normal sleep is back; SleepDisabled = $(pmset -g | awk '/SleepDisabled/ {print $2}')"

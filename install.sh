#!/bin/bash
# Installs lid-awake: Claude Code hooks, a sudo rule for pmset, a login
# failsafe that restores normal sleep if a session dies mid-turn, and the
# menu bar icon. Safe to re-run. Undo everything with uninstall.sh.
set -euo pipefail

DIR="$HOME/.claude/lid-awake"
SCRIPT="$DIR/lid-awake.sh"
MENU="$DIR/LidAwakeMenu"
SETTINGS="$HOME/.claude/settings.json"
AGENTS="$HOME/Library/LaunchAgents"
FAILSAFE="$AGENTS/com.$USER.claude-lid-awake.plist"
MENU_AGENT="$AGENTS/com.$USER.claude-lid-awake-menu.plist"
SUDOERS=/etc/sudoers.d/claude-lid-awake

# The source lives on the Desktop; macOS privacy rules keep launchd from reading
# it there, so the runtime copy goes to ~/.claude/lid-awake.
SRC="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR"
install -m 0755 "$SRC/lid-awake.sh" "$SCRIPT"

echo "1/4 Adding hooks to $SETTINGS (backup: settings.json.bak-before-lid-awake)"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.bak-before-lid-awake" ] || cp -p "$SETTINGS" "$SETTINGS.bak-before-lid-awake"
/usr/bin/python3 -I - "$SETTINGS" "$SCRIPT" <<'EOF'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
s = json.load(open(path))  # stops here, file untouched, if settings.json is not valid JSON
hooks = s.setdefault('hooks', {})
# Drop lid-awake entries from every event first (including older installs).
for ev in list(hooks):
    hooks[ev] = [e for e in hooks[ev]
                 if not any('lid-awake.sh' in h.get('command', '') for h in e.get('hooks', []))]
    if not hooks[ev]: del hooks[ev]
for ev in ('UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest',
           'Notification', 'Stop', 'SessionEnd'):
    hooks.setdefault(ev, []).append(
        {"hooks": [{"type": "command", "command": f'"{cmd}" hook', "timeout": 5}]})
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(s, f, indent=2); f.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, path)
EOF

echo "2/4 Allowing passwordless 'pmset -a disablesleep 0|1' only (asks for your password once)"
RULE="$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
TMP=$(mktemp)
echo "$RULE" > "$TMP"
sudo visudo -cf "$TMP" >/dev/null
sudo install -m 0440 -o root -g wheel "$TMP" "$SUDOERS"
rm -f "$TMP"

echo "3/4 Building the menu bar icon"
swiftc -O "$SRC/menubar/LidAwakeMenu.swift" -o "$MENU"

echo "4/4 Installing login items (failsafe every 5 min, menu bar icon)"
mkdir -p "$AGENTS"
agent() { # <plist> <label> <extra plist keys> <program args...>
  local plist=$1 label=$2 extra=$3; shift 3
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array>'
    for a in "$@"; do echo "    <string>$a</string>"; done
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo "  $extra"
    echo '</dict></plist>'
  } > "$plist"
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
}
agent "$FAILSAFE" "com.$USER.claude-lid-awake" '<key>StartInterval</key><integer>300</integer>' /bin/bash "$SCRIPT" check
agent "$MENU_AGENT" "com.$USER.claude-lid-awake-menu" '' "$MENU"

echo
"$SCRIPT" status | grep -E '^(sudo|watchdog|lid|power|battery)='
echo
echo "Done. Restart any open Claude sessions (CLI and desktop app) so they load the hooks."

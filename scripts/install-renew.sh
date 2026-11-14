#!/bin/zsh
# Installs (or removes with --uninstall) the macOS task that renews DingDing every 3 h.
set -eu
LABEL="dingding.renew"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="${0:A:h}/renew.sh"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  print "Tâche de renouvellement supprimée."
  exit 0
fi

[[ -f "${0:A:h}/renew.env" ]] || { print "Crée d'abord scripts/renew.env (voir renew.env.example)." >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/zsh</string><string>$SCRIPT</string></array>
	<key>StartInterval</key><integer>10800</integer>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/DingDing-renew.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/DingDing-renew.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
print "Tâche installée : DingDing sera renouvelée automatiquement (journal : ~/Library/Logs/DingDing-renew.log)."

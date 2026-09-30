#!/bin/zsh
# Builds the tool and installs a LaunchAgent that runs it every syncIntervalMinutes (settings.json).
# On first run it creates settings.json from settings.example.json and stops so you can fill it in.
set -euo pipefail

DIR="${0:A:h}"
BIN="$HOME/.local/bin/m365-calendar-sync"
LABEL="com.fedeagostini.m365-calendar-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/m365-calendar-sync.log"
SETTINGS="$HOME/Library/Application Support/m365-calendar-sync/settings.json"

mkdir -p "${BIN:h}" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "${SETTINGS:h}"

if [[ ! -f "$SETTINGS" ]]; then
  cp "$DIR/settings.example.json" "$SETTINGS"
  echo "Created $SETTINGS"
  echo "Fill in your accounts there, then run $0 again."
  exit 1
fi

setting() { plutil -extract "$1" raw -o - "$SETTINGS" 2>/dev/null || true; }

plutil -convert xml1 -o /dev/null "$SETTINGS" 2>/dev/null || { echo "$SETTINGS is not valid JSON" >&2; exit 1; }
for key in sourceAccount targetAccount; do
  value="$(setting $key)"
  if [[ -z "$value" || "$value" == my.user@* ]]; then
    echo "Set \"$key\" in $SETTINGS first." >&2
    exit 1
  fi
done
INTERVAL_MIN="$(setting syncIntervalMinutes)"
[[ "$INTERVAL_MIN" == <-> && "$INTERVAL_MIN" -ge 1 ]] || INTERVAL_MIN=15

# The embedded Info.plist lets macOS show the Calendar permission prompt for this binary.
swiftc -O -swift-version 5 "$DIR/sync.swift" -o "$BIN" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist"
codesign --force --sign - --identifier "$LABEL" "$BIN"

# The menu bar app rewrites this same plist when the interval changes (writeSyncAgent). Keep the two in step.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string></array>
    <key>StartInterval</key><integer>$((INTERVAL_MIN * 60))</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl enable "gui/$(id -u)/$LABEL"  # undo a Stop from the menu bar icon
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed sync job (every $INTERVAL_MIN min). Settings: $SETTINGS  Log: $LOG"

# Menu bar icon: ~/Applications/M365 Sync.app, started at login.
APP="$HOME/Applications/M365 Sync.app"
MENU_LABEL="$LABEL.menubar"
MENU_PLIST="$HOME/Library/LaunchAgents/$MENU_LABEL.plist"

launchctl bootout "gui/$(id -u)/$MENU_LABEL" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/menubar/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 "$DIR/menubar/MenuBar.swift" -o "$APP/Contents/MacOS/M365 Sync"
codesign --force --sign - "$APP"

cat > "$MENU_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$MENU_LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/M365 Sync</string></array>
    <key>RunAtLoad</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$MENU_PLIST"
echo "Installed menu bar icon: $APP"

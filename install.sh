#!/bin/zsh
# Builds Logic Click Locate from source, installs it to ~/Applications and starts it at every login.
# Needs Apple's Command Line Tools (for swiftc): xcode-select --install
set -e
cd "${0:A:h}"
APP="build/Logic Click Locate.app"
DEST="$HOME/Applications/Logic Click Locate.app"
LABEL=local.LogicClickLocate
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Command Line Tools: xcode-select --install"; exit 1; }

rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O LogicClickLocate.swift -o "$APP/Contents/MacOS/LogicClickLocate"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"   # ad-hoc signature, local use only

launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST" && cp -R "$APP" "$DEST"

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/LogicClickLocate</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) "$AGENT"

echo
echo "Installed: $DEST (starts at login)."
echo "Now allow it in System Settings > Privacy & Security > Accessibility > Logic Click Locate."
echo "After reinstalling, remove it from that list and allow it again (each build has a new signature)."

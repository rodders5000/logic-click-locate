#!/bin/zsh
# Stops Logic Click Locate and removes the app and its login agent.
LABEL=local.LogicClickLocate
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Logic Click Locate.app"
echo "Removed. You can also delete its entry in System Settings > Privacy & Security > Accessibility."

#!/bin/sh
# Removes MenuStats completely: Homebrew install, background agent, tap, a hand-built copy,
# cached downloads and preferences. Does not touch anything else.
set -u

say() { printf '%s\n' "$*"; }

if command -v brew >/dev/null 2>&1; then
    if brew list --formula menustats >/dev/null 2>&1; then
        brew services stop menustats >/dev/null 2>&1 && say "Stopped the MenuStats background service"
        brew uninstall --force menustats && say "Uninstalled the Homebrew formula"
    fi
    brew untrust --formula gyane14/tap/menustats >/dev/null 2>&1
    brew untrust gyane14/tap >/dev/null 2>&1
    if brew tap | grep -qx 'gyane14/tap'; then
        brew untap gyane14/tap && say "Removed the gyane14/tap tap"
    fi
    cache=$(brew --cache)
    rm -f "$cache"/downloads/*menustats* "$cache"/menustats--* && say "Cleared cached downloads"
fi

# leftover agent if Homebrew is already gone
agent="$HOME/Library/LaunchAgents/sh.brew.menustats.plist"
if [ -f "$agent" ]; then
    launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null
    rm -f "$agent" && say "Removed the login agent"
fi

pkill -x MenuStats 2>/dev/null && say "Quit the running MenuStats"

# a copy built with ./build.sh (its login item disappears once the app is deleted)
if [ -d "$HOME/Applications/MenuStats.app" ]; then
    rm -rf "$HOME/Applications/MenuStats.app" && say "Deleted ~/Applications/MenuStats.app"
fi

for domain in io.github.gyane14.menustats local.menustats; do
    defaults delete "$domain" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$domain.plist"
done
say "Removed preferences"

say "MenuStats is removed. If it still appears in System Settings > General > Login Items, remove it there."

#!/bin/sh
# Builds MenuStats.app into ~/Applications
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/MenuStats.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/MenuStats"
cp Info.plist "$APP/Contents/"
codesign --force -s - "$APP"
echo "Built $APP"

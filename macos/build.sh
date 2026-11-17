#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$task_root/dist/Arduino Voice Bridge.app}"
arch="$(uname -m)"
mkdir -p "$output/Contents/MacOS" "$task_root/.build/ModuleCache"
/usr/bin/swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" \
  -module-cache-path "$task_root/.build/ModuleCache" \
  "$task_root/macos/VoiceBridge.swift" -o "$output/Contents/MacOS/ArduinoVoiceBridge" \
  -framework AppKit -framework ApplicationServices
/bin/cp "$task_root/macos/Info.plist" "$output/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier hk.edu.int4089.ArduinoVoiceBridge "$output"
"$output/Contents/MacOS/ArduinoVoiceBridge" --self-test
printf '%s\n' "$output"

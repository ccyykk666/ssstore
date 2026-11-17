#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/LocalPerformanceCheck.app/Contents"
mkdir -p "$app/MacOS"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.personal.local-performance-test</string>
<key>CFBundleExecutable</key><string>LocalPerformanceCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun --sdk macosx clang -fobjc-arc -fmodules -I ssstore/Bridge \
  ssstore/Bridge/LocalPerformance.m scripts/tests/LocalPerformanceChecks.m \
  -framework Foundation -o "$app/MacOS/LocalPerformanceCheck"
"$app/MacOS/LocalPerformanceCheck"

swiftc -parse-as-library ssstore/CurrentValueRefresh.swift scripts/tests/CurrentValueRefreshChecks.swift -o "$probe_dir/current-value-checks"
"$probe_dir/current-value-checks"

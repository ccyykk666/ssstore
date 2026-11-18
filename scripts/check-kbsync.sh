#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library ssstore/KBSyncGenerator.swift scripts/tests/KBSyncSmoke.swift \
  -framework WebKit -framework AppKit -o "$check_dir/kbsync-check"
"$check_dir/kbsync-check" "$PWD/build/KBSyncRuntime"

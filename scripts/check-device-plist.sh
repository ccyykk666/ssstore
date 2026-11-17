#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
slice="$PWD/Packages/DeviceKit/IDevice.xcframework/macos-arm64_x86_64"
probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fmodules -I "$slice/Headers" -I ssstore/Bridge \
  scripts/tests/DevicePlistChecks.m "$slice/idevice-macos.a" \
  -framework Foundation -framework CoreFoundation -framework Security -framework SystemConfiguration -framework IOKit \
  -Wl,-dead_strip -lresolv -liconv -lc++ \
  -o "$probe_dir/plist-checks"
"$probe_dir/plist-checks"
python3 - "$probe_dir/plist-checks" <<'PY'
import subprocess,sys,signal
result = subprocess.run([sys.argv[1], '--legacy-xml'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if result.returncode != -signal.SIGABRT:
    raise SystemExit('Expected legacy XML serializer to abort on the UID fixture; got '+str(result.returncode))
print('Confirmed legacy XML abort in isolated process; production binary conversion completes')
result = subprocess.run([sys.argv[1], '--legacy-empty-array'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if result.returncode not in (-signal.SIGABRT, -signal.SIGSEGV, -signal.SIGBUS):
    raise SystemExit('Expected legacy empty-slice cleanup to crash; got '+str(result.returncode))
print('Confirmed legacy empty-slice invalid free; production zero-length cleanup completes')
PY

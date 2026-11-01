#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -d Packages/DeviceKit/IDevice.xcframework ]]; then
  echo "IDevice.xcframework 已就绪。"
  exit 0
fi
mkdir -p build
archive="$PWD/build/idevice-xcframework-v0.1.68.zip"
curl -fL --retry 2 \
  'https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip' \
  -o "$archive"
echo "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7  $archive" | shasum -a 256 -c -
stage=$(mktemp -d "$PWD/build/devicekit.XXXXXX")
unzip -q "$archive" 'swift/IDevice.xcframework/*' -d "$stage"
cp -R "$stage/swift/IDevice.xcframework" Packages/DeviceKit/IDevice.xcframework
echo "已准备 idevice v0.1.68。"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "请先安装 XcodeGen：brew install xcodegen" >&2
  exit 1
fi

swift test --package-path Packages/UpdateCore
bash Vendor/Asspp/Resources/Scripts/check.downloads.sh
bash scripts/prepare-devicekit.sh
xcodegen generate
mkdir -p ssstore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Vendor/Asspp/Asspp.xcworkspace/xcshareddata/swiftpm/Package.resolved \
  ssstore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project ssstore.xcodeproj -scheme ssstore \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

app="$PWD/build/DerivedData/Build/Products/Release-iphoneos/ssstore.app"
if [[ ! -d "$app" ]]; then
  echo "未找到编译产物：$app" >&2
  exit 1
fi
# Each build gets its own staging folder; no existing output folders are removed.
mkdir -p dist
stage=$(mktemp -d "$PWD/build/ipa.XXXXXX")
mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/ssstore.app"
output="$stage/ssstore.ipa"
(cd "$stage" && /usr/bin/zip -qry "$output" Payload)
cp "$output" "$PWD/dist/ssstore.ipa"
echo "已生成待自签 IPA：$PWD/dist/ssstore.ipa"


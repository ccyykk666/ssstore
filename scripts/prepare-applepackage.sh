#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

revision=773583a29c6b1f1b0d0783d0a15d3ddafcd85eec
archive_sha=722aa28cfa377b8a677edba0dcfa7af6475451fb769f59e344aa7c038ff92037
patch_file="$PWD/scripts/applepackage-authentication.patch"
route_file="$PWD/scripts/applepackage-authentication-route.swift"
package="$PWD/build/ApplePackage"
patch_sha=$(shasum -a 256 "$patch_file" | cut -d ' ' -f 1)
route_sha=$(shasum -a 256 "$route_file" | cut -d ' ' -f 1)
stamp="$revision $patch_sha $route_sha"
if [[ -f "$package/.ssstore-input" && -f "$package/Package.swift" ]] &&
   [[ "$(cat "$package/.ssstore-input")" == "$stamp" ]]; then
    exit 0
fi

mkdir -p build
stage=$(mktemp -d "$PWD/build/applepackage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
curl -fsSL --max-time 60 --retry 2 \
    "https://codeload.github.com/Lakr233/ApplePackage/tar.gz/$revision" -o "$stage/source.tar.gz"
printf '%s  %s\n' "$archive_sha" "$stage/source.tar.gz" | shasum -a 256 -c
mkdir "$stage/source"
tar -xzf "$stage/source.tar.gz" -C "$stage/source" --strip-components=1
patch -d "$stage/source" -p1 < "$patch_file"
cp "$route_file" "$stage/source/Sources/ApplePackage/Commands/AuthenticationRoute.swift"
printf '%s\n' "$stamp" > "$stage/source/.ssstore-input"
rm -rf "$package"
mv "$stage/source" "$package"

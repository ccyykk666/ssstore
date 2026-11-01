#!/bin/bash
set -euo pipefail
check_kind=${1:-all}
case "$check_kind" in
    all|protocol|localization) ;;
    *) echo "Usage: $0 [all|protocol|localization]" >&2; exit 2 ;;
esac
download_repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
download_check_dir=$(mktemp -d)
trap 'rm -rf "$download_check_dir"' EXIT
cd "$download_repo_dir"
if [[ "$check_kind" != localization ]]; then
    swiftc Asspp/Backend/AppStore/StoreProtocol.swift \
    Asspp/Backend/AppStore/StoreDiagnostics.swift \
    Asspp/Backend/AppStore/StoreDownloadProtocol.swift \
    Asspp/Backend/AppStore/StoreHistoryProtocol.swift \
    Resources/Tests/HistoryProtocolChecks.swift \
    Resources/Tests/DownloadProtocolChecks.swift -o "$download_check_dir/download-checks"
    "$download_check_dir/download-checks"
fi
if [[ "$check_kind" != protocol ]]; then
    /usr/bin/python3 Resources/Tests/LocalizationChecks.py Asspp/Backend/AppStore/StoreDownloadProtocol.swift
fi



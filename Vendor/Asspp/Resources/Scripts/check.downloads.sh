#!/bin/bash
set -euo pipefail
check_kind=${1:-all}
case "$check_kind" in
    all|protocol|localization) ;;
    *) echo "Usage: $0 [all|protocol|localization]" >&2; exit 2 ;;
esac
download_repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
download_check_dir=$(mktemp -d)
transfer_server_pid=""
trap 'if [[ -n "$transfer_server_pid" ]]; then kill "$transfer_server_pid" 2>/dev/null || true; fi; rm -rf "$download_check_dir"' EXIT
cd "$download_repo_dir"
if [[ "$check_kind" != localization ]]; then
    swiftc Asspp/Backend/AppStore/StoreProtocol.swift \
    Asspp/Backend/AppStore/StoreDiagnostics.swift \
    Asspp/Backend/AppStore/StoreDownloadProtocol.swift \
    Asspp/Backend/AppStore/StoreHistorySupport.swift \
    Asspp/Backend/AppStore/StoreCatalogHistoryService.swift \
    Resources/Tests/HistorySupportChecks.swift \
    Resources/Tests/DownloadProtocolChecks.swift -o "$download_check_dir/download-checks"
    "$download_check_dir/download-checks"
    swiftc Asspp/Backend/Downloader/PackageTransfer.swift Resources/Tests/TransferChecks.swift -o "$download_check_dir/transfer-checks"
    python3 Resources/Tests/TransferServer.py "$download_check_dir/port" &
    transfer_server_pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$download_check_dir/port" ]] && break
        sleep 0.02
    done
    "$download_check_dir/transfer-checks" "http://127.0.0.1:$(cat "$download_check_dir/port")"
fi
if [[ "$check_kind" != protocol ]]; then
    /usr/bin/python3 Resources/Tests/LocalizationChecks.py Asspp/Backend/AppStore/StoreDownloadProtocol.swift
fi



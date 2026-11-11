"""Select checks relative to a successful build, not merely the previous commit."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request


STORE = "Vendor/Asspp/"
CHECK_INPUTS = {
    "native_sheet": (
        "ssstore/UIKit/NativeInterface.swift",
        "ssstore/UIKit/NativeFittingNavigation.swift",
        "tests/native-sheet/",
    ),
    "manifest_credentials": (
        "ssstore/ManifestAPICredentials.swift",
        "ssstore/InstallerManifestService.swift",
        "ssstore/UIKit/ManifestServiceScreen.swift",
        "scripts/tests/ManifestCredentialChecks.swift",
    ),
    "core": (
        "Packages/UpdateCore/",
        STORE + "Asspp/Backend/Installer/",
        "ssstore/CompatibleInstallBackgroundExecution.swift",
        "ssstore/StoreRuntime.swift",
        "ssstore/UIKit/StoreScreens.swift",
    ),
    "downloads": (
        STORE + "Asspp/Backend/AppStore/AppStore.swift",
        STORE + "Asspp/Backend/AppStore/AuthenticationService.swift",
        STORE + "Asspp/Backend/Downloader/Downloads.swift",
        STORE + "Asspp/Backend/Downloader/PackageTransfer.swift",
        STORE + "Asspp/Backend/Downloader/ParallelPackageTransfer.swift",
        STORE + "Asspp/Backend/Downloader/PackageState.swift",
        STORE + "Resources/Tests/TransferChecks.swift",
        STORE + "Resources/Tests/TransferServer.py",
        STORE + "Asspp/Backend/Downloader/Downloads+UI.swift",
        STORE + "Asspp/Backend/AppStore/AppPackageArchive.swift",
        STORE + "Asspp/Backend/AppStore/StoreProtocol.swift",
        STORE + "Asspp/Backend/AppStore/StoreDiagnostics.swift",
        STORE + "Asspp/Backend/AppStore/StoreDownloadProtocol.swift",
        STORE + "Asspp/Backend/AppStore/StoreDownloadService.swift",
        STORE + "Asspp/Backend/AppStore/StoreHistorySupport.swift",
        STORE + "Asspp/Backend/AppStore/StoreCatalogHistoryService.swift",
        STORE + "Resources/Tests/HistorySupportChecks.swift",
        STORE + "Resources/Tests/DownloadProtocolChecks.swift",
        STORE + "Resources/Scripts/check.downloads.sh",
    ),
    "localization": (
        STORE + "Asspp/App/Localizable.xcstrings",
        STORE + "Asspp/Backend/AppStore/StoreDownloadProtocol.swift",
        STORE + "Resources/Tests/LocalizationChecks.py",
        STORE + "Resources/Scripts/check.downloads.sh",
    ),
    "kbsync": (
        "ssstore/KBSyncGenerator.swift",
        STORE + "Asspp/Backend/AppStore/StoreDownloadService.swift",
        "scripts/prepare-kbsync.py",
        "scripts/kbsync-manifest.json",
        "scripts/kbsync-runtime.ts",
        "scripts/kbsync-worker.ts",
        "scripts/kbsync-index.html",
        "scripts/check-kbsync.sh",
        "scripts/tests/KBSyncSmoke.swift",
    ),
    "selection": (
        "scripts/select-ci-tests.py",
        "scripts/tests/",
        ".github/workflows/build-ios.yml",
    ),
}


def select_checks(paths):
    return {
        name: any(path.startswith(rule) if rule.endswith("/") else path == rule
                  for path in paths for rule in rules)
        for name, rules in CHECK_INPUTS.items()
    }


def git(*args):
    return subprocess.check_output(["git", *args])


def changed_paths(base, head="HEAD"):
    # Disable rename detection so both old and new paths participate in selection.
    return [p.decode("utf-8", errors="surrogateescape") for p in
            git("diff", "--name-only", "--no-renames", "-z", base, head, "--").split(b"\0") if p]


def successful_baseline(head):
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GH_TOKEN"]
    branch = os.environ.get("GITHUB_HEAD_REF") or os.environ["GITHUB_REF_NAME"]
    fallback = os.environ.get("GITHUB_BASE_REF") or os.environ.get("CI_DEFAULT_BRANCH", "main")
    current_run = str(os.environ["GITHUB_RUN_ID"])
    for candidate in dict.fromkeys((branch, fallback)):
        query = urllib.parse.urlencode({"branch": candidate, "status": "success", "per_page": 100})
        url = f"https://api.github.com/repos/{repo}/actions/workflows/build-ios.yml/runs?{query}"
        request = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(request, timeout=20) as response:
            runs = json.load(response)["workflow_runs"]
        # PR head_sha is not the synthetic merge commit actually tested by checkout.
        # Only use runs whose checked-out commit is represented by head_sha.
        runs = [run for run in runs if str(run["id"]) != current_run and
                run["conclusion"] == "success" and run["event"] in ("push", "workflow_dispatch")]
        if runs:
            matching = next((run for run in runs if run["head_sha"] == head), runs[0])
            return matching["head_sha"]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Explicit validated commit for a local selection check")
    args = parser.parse_args()
    os.chdir(Path(__file__).resolve().parents[1])
    head = git("rev-parse", "HEAD").decode().strip()
    base = args.base
    try:
        if not base:
            base = successful_baseline(head)
        if not base:
            raise ValueError("No successful build baseline is available")
        checks = select_checks(changed_paths(base, head))
        reason = f"Compared with successful build commit {base[:12]}"
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        # Unknown history must not silently suppress checks (including failed-push gaps).
        checks = dict.fromkeys(CHECK_INPUTS, True)
        reason = f"Cannot establish validated baseline ({type(error).__name__}); run all checks"
    print(reason)
    for name, enabled in checks.items():
        print(f"{name}: {'run' if enabled else 'skip (relevant inputs unchanged)'}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            for name, enabled in checks.items():
                stream.write(f"{name}={str(enabled).lower()}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write("### Selected checks\n\n" + reason + "\n\n")
            for name, enabled in checks.items():
                stream.write(f"- {name}: {'run' if enabled else 'skipped; inputs unchanged'}\n")


if __name__ == "__main__":
    main()

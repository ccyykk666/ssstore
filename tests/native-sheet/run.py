"""Exercise the production adaptive navigation container in an iOS simulator."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
PHASE = "preparing"


def phase(name):
    global PHASE
    PHASE = name
    print("Native sheet probe: " + name, flush=True)


def run(*args, timeout=180, capture=False):
    result = subprocess.run(list(map(str, args)), timeout=timeout, text=True, capture_output=True)
    if not capture:
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", flush=True)
    if result.returncode:
        errors = [line.strip() for line in (result.stdout + result.stderr).splitlines() if "error:" in line.lower()]
        reason = " | ".join(errors[:3]) or result.stderr.strip()[-1000:] or f"exit {result.returncode}"
        raise RuntimeError(f"{args[0]} failed: {reason}")
    return result


def source(revision):
    def read(path):
        if revision:
            return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()
    path = "ssstore/UIKit/NativeFittingNavigation.swift"
    exists = subprocess.run(["git", "cat-file", "-e", f"{revision}:{path}"], cwd=ROOT,
                            capture_output=True).returncode == 0 if revision else (ROOT / path).exists()
    if exists:
        return read(path)
    text = read("ssstore/UIKit/NativeInterface.swift")
    start = text.index("/// Native scrollable content shares the adaptive UIKit sheet container.")
    end = text.index("@MainActor\nclass NativePage:", start)
    # The legacy settings entry used the content-fitting container. Adapt its
    # old factory shape so the same UI scenario can compare a historical SHA.
    legacy_factory = """
@MainActor
enum NativeSheetNavigation {
    static func settings(root: UIViewController & NativeSheetContent) -> UINavigationController {
        NativeFittingNavigation(root: root)
    }
}
"""
    return "import UIKit\n\n" + text[start:end] + legacy_factory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="")
    parser.add_argument("--output", default="build/native-sheet-results")
    args = parser.parse_args()
    if args.revision and not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        parser.error("revision must be a full commit SHA")
    output = (ROOT / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="sheet-probe-", dir=output))
    (stage / "NativeFittingNavigation.swift").write_text(source(args.revision))
    shutil.copyfile(ROOT / "tests/native-sheet/Probe.swift", stage / "Probe.swift")
    config = {"name": "NativeSheetProbe", "options": {"deploymentTarget": {"iOS": "17.0"}}, "targets": {
        "NativeSheetProbe": {"type": "application", "platform": "iOS", "sources": ["Probe.swift", "NativeFittingNavigation.swift"],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "dev.personal.ssstore.NativeSheetProbe", "SWIFT_VERSION": "5.9", "TARGETED_DEVICE_FAMILY": "1"}},
            "info": {"path": "Info.plist", "properties": {"UILaunchScreen": {}, "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {}},
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]}}}}}
    spec = stage / "project.json"
    spec.write_text(json.dumps(config))
    phase("generating simulator fixture")
    run("xcodegen", "generate", "--spec", spec)
    derived = stage / "DerivedData"
    phase("building simulator fixture")
    run("xcodebuild", "-quiet", "-project", stage / "NativeSheetProbe.xcodeproj", "-scheme", "NativeSheetProbe",
        "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", "build", timeout=300)
    fixture = derived / "Build/Products/Debug-iphonesimulator/NativeSheetProbe.app"
    phase("signing simulator fixture")
    run("codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", fixture, capture=True)
    run("codesign", "--verify", "--deep", "--strict", fixture, capture=True)
    # Hosted runners are disposable, isolated VMs. Reset their simulator service
    # before creating our device; never do this on a shared/self-hosted machine.
    if os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted":
        phase("resetting hosted simulator service")
        subprocess.run(["killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService"],
                       capture_output=True, timeout=15)
    phase("locating simulator runtime")
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json", capture=True).stdout)["runtimes"]
    available = [r for r in runtimes if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
    if not available:
        raise RuntimeError("No iOS simulator runtime is installed; no UI result can be claimed")
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version", capture=True).stdout.strip()
    sdk_version = tuple(map(int, sdk.split(".")))
    compatible = [r for r in available if int(r["version"].split(".")[0]) == sdk_version[0]
                  and tuple(map(int, r["version"].split(".")[:2])) <= sdk_version[:2]]
    if not compatible:
        raise RuntimeError("No runtime matching the selected iOS SDK " + sdk + "; available: " +
                           ", ".join(r["name"] for r in available))
    runtime = max(compatible, key=lambda r: tuple(map(int, r["version"].split("."))))
    print("::notice title=Simulator runtime::SDK=" + sdk + "; selected=" + runtime["name"] +
          "; available=" + ", ".join(r["name"] for r in available), flush=True)
    devices = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json", capture=True).stdout)["devicetypes"]
    # Use runtime compatibility metadata, never a hard-coded phone model. A
    # configured device supplies a compatible type without touching that device.
    configured = json.loads(run("xcrun", "simctl", "list", "devices", "--json", capture=True).stdout)["devices"]
    supported = {item["identifier"] if isinstance(item, dict) else item for item in runtime.get("supportedDeviceTypes", [])}
    supported.update(d["deviceTypeIdentifier"] for d in configured.get(runtime["identifier"], [])
                     if d.get("isAvailable") and d.get("deviceTypeIdentifier") and d["name"].startswith("iPhone"))
    candidates = [d for d in devices if d["name"].startswith("iPhone") and d["identifier"] in supported]
    if not candidates:
        version = tuple(map(int, runtime["version"].split(".")))
        version = version + (0,) * (3-len(version))
        def compatible(d):
            low = tuple(map(int, d.get("minRuntimeVersionString", "0.0.0").split(".")))
            high = tuple(map(int, d.get("maxRuntimeVersionString", "65535.255.255").split(".")))
            return d["name"].startswith("iPhone") and low <= version <= high
        candidates = [d for d in devices if compatible(d)]
    if not candidates:
        raise RuntimeError("No compatible iPhone type is installed for " + runtime["name"])
    device_type = candidates[0]
    phase("creating " + device_type["name"] + " for " + runtime["name"])
    device = run("xcrun", "simctl", "create", "ssstore-sheet-probe-" + stage.name, device_type["identifier"], runtime["identifier"], capture=True).stdout.strip()
    bundle = "dev.personal.ssstore.NativeSheetProbe"
    report = None
    pid = None
    try:
        phase("booting " + runtime["name"])
        run("xcrun", "simctl", "boot", device)
        run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
        phase("waiting for simulator app services on " + runtime["name"] + " / " + device_type["name"])
        run("xcrun", "simctl", "listapps", device, capture=True, timeout=60)
        phase("installing simulator fixture")
        run("xcrun", "simctl", "install", device, fixture)
        container = Path(run("xcrun", "simctl", "get_app_container", device, bundle, "data", capture=True).stdout.strip())
        phase("launching simulator fixture")
        launched = run("xcrun", "simctl", "launch", device, bundle, capture=True).stdout.strip()
        print(launched, flush=True)
        pid = re.search(r": (\d+)$", launched).group(1)
        phase("interacting with sheet")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                report = json.loads((container / "Documents/probe.json").read_text())
                if report["status"] != "running":
                    break
            except (OSError, json.JSONDecodeError):
                pass
            time.sleep(0.2)
        if not report or report["status"] != "passed":
            subprocess.run(["sample", pid, "2", "1", "-file", str(output / "main-thread-sample.txt")], capture_output=True, timeout=15)
        (output / "probe.json").write_text(json.dumps(report or {"status": "no-report"}, indent=2, ensure_ascii=False))
        subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(output / "screen.png")], capture_output=True, timeout=15)
        print(json.dumps(report, ensure_ascii=False), flush=True)
        if not report or report["status"] != "passed":
            state = {key: report.get(key) for key in ["status", "phase", "measurements", "system"]} if report else {"status": "no-report"}
            raise RuntimeError("Sheet UI probe failed or stopped responding: " + json.dumps(state))
        print("Native sheet UI probe passed on " + runtime["name"], flush=True)
    finally:
        for command, timeout in [("terminate", 15), ("shutdown", 30), ("delete", 30)]:
            try:
                extra = [bundle] if command == "terminate" else []
                subprocess.run(["xcrun", "simctl", command, device, *extra], capture_output=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                # Preserve the actual test/setup failure when Simulator itself
                # is unresponsive during best-effort cleanup of our own device.
                print("Simulator cleanup timed out: " + command, flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Normal CI failure annotations identify the *new run's* failing stage
        # without requiring a log or artifact download to interpret its status.
        message = f"Native sheet probe failed while {PHASE}: {error}"
        escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Native sheet probe::" + escaped, flush=True)
        raise

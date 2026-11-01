"""Generate the in-app reference from the pinned XCFramework's idevice.h.

Usage: python3 scripts/generate-api-index.py /path/to/idevice.h
This script reads declarations only; it never invokes a device API.
"""
from pathlib import Path
import json
import re
import sys

root = Path(__file__).resolve().parent.parent
header = Path(sys.argv[1]).read_text(encoding="utf-8")
source = (root / "ssstore/Bridge/DeviceInspector.m").read_text(encoding="utf-8")
used = set(re.findall(r"\b([a-z][a-z0-9_]+)\s*\(", source))
for base in re.findall(r"CONNECT\(\s*([a-z][a-z_]+)\s*,", source):
    used.add(base + "_connect_rsd")
for base in re.findall(r"PROBE_SERVICE\(\s*([a-z][a-z_]+)\s*,", source):
    used.add(base + "_connect_rsd")
entries = []
for match in re.finditer(r"^[ \t]*(?!typedef\b)(?:[A-Za-z_]\w*[\s*]+)+(?P<name>[A-Za-z_]\w*)\s*\([^;{}]*\)\s*;", header, re.M):
    name = match.group("name")
    before = header[:match.start()]
    start = before.rfind("/**")
    comment = before[start:] if start >= 0 and before[start:].rstrip().endswith("*/") else ""
    lines = [re.sub(r"^\s*\*\s?", "", line).strip() for line in comment.splitlines()[1:]]
    summary = []
    for line in lines:
        if not line and summary:
            break
        if line and line != "/" and not line.startswith("#"):
            summary.append(line)
    entries.append({"name": name, "signature": re.sub(r"\s+", " ", match.group(0)).strip(),
                    "summary": " ".join(summary), "used": name in used})
output = root / "ssstore/Resources/DeviceAPIIndex.json"
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
known = {entry["name"] for entry in entries}
prefixes = ("app_service_", "device_info_", "configuration_service_", "file_service_", "rsd_", "springboard_", "afc_",
            "misagent_", "lockdownd_", "diagnostics_relay_", "screenshot", "application_listing_", "image_mounter_",
            "companion_proxy_", "crash_report_", "remote_server_")
unknown = sorted(name for name in used if name.startswith(prefixes) and name not in known)
if unknown:
    raise SystemExit(f"Unknown pinned device symbols: {unknown}")
print(f"Indexed {len(entries)} C declarations; inspector uses {sum(entry['used'] for entry in entries)}.")


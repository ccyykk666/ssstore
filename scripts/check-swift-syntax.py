"""Catch App syntax errors before resolving or compiling external dependencies."""
from pathlib import Path
import subprocess

sources = sorted(str(path) for path in Path("ssstore").rglob("*.swift"))
subprocess.run(["swiftc", "-frontend", "-parse", *sources], check=True)

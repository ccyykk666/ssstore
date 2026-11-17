"""Build pinned idevice with the RSD discovery compatibility fix."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import re
import tempfile
from collections import deque

ROOT = Path(__file__).resolve().parents[1]
COMMIT = "d32c8189c51c2789496b0768039419c3705498c3"
SOURCE_SHA256 = "f037aa4bcb31b161b9ed97aeb223374736a3bdead2dfcc7c9b0bff1b81483a0d"

def run(*args, **kwargs):
    process = subprocess.Popen(list(map(str, args)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kwargs)
    tail = deque(maxlen=30)
    for line in process.stdout:
        print(line, end="", flush=True); tail.append(line)
    code = process.wait()
    if code:
        message = re.sub(r"https?://\S+", "<URL redacted>", "".join(tail))[-5000:]
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Performance dependency::" + message, flush=True)
        raise subprocess.CalledProcessError(code, list(map(str, args)))

def main():
    os.chdir(ROOT)
    patches = [ROOT / "scripts/patches/rsd-discovery.patch"]
    digest = hashlib.sha256(COMMIT.encode() + b"".join(p.read_bytes() for p in patches)).hexdigest()
    cache = ROOT / "build/PerformanceDeviceKit"
    library = cache / f"{digest}.a"
    cache.mkdir(parents=True, exist_ok=True)
    if not library.exists():
        archive = cache / "source.tar.gz"
        if not archive.exists():
            url = f"https://api.github.com/repos/jkcoxson/idevice/tarball/{COMMIT}"
            pending_archive = archive.with_suffix(".pending")
            with urllib.request.urlopen(url, timeout=60) as response, pending_archive.open("wb") as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(pending_archive.read_bytes()).hexdigest() != SOURCE_SHA256:
                raise ValueError("Pinned idevice source archive checksum mismatch")
            pending_archive.replace(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_SHA256:
            raise ValueError("Pinned idevice source archive checksum mismatch")
        source = cache / f"source-{digest}"
        if not source.exists():
            with tempfile.TemporaryDirectory(prefix="extract-", dir=cache) as temporary:
                stage = Path(temporary)
                with tarfile.open(archive) as tar: tar.extractall(stage, filter="data")
                roots = list(stage.iterdir())
                if len(roots) != 1: raise ValueError("Unexpected source archive layout")
                rsd_module = roots[0] / "idevice/src/services/rsd.rs"
                if hashlib.sha256(rsd_module.read_bytes()).hexdigest() != "bdb483a6bbc30b586e4d2d04190d432219059149298c2bca85f9033042bd03f7":
                    raise ValueError("Pinned RSD discovery source mismatch")
                run("patch", "-p1", "-i", patches[0], cwd=roots[0], stdin=subprocess.DEVNULL)
                roots[0].rename(source)
        env = os.environ.copy()
        env["CARGO_TARGET_DIR"] = str(ROOT / "build/PerformanceCargo")
        env["RUSTUP_TOOLCHAIN"] = "1.94.0"
        env["RUSTC"] = subprocess.check_output(["rustup", "which", "--toolchain", "1.94.0", "rustc"], text=True).strip()
        run("rustup", "run", "1.94.0", "cargo", "test", "--manifest-path", source / "Cargo.toml", "--locked", "-p", "idevice", "--lib",
            "--no-default-features", "--features", "rsd,ring", "ssstore_rsd", env=env)
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        env.update(BINDGEN_EXTRA_CLANG_ARGS=f"--sysroot={sdk}", IPHONEOS_DEPLOYMENT_TARGET="17.0")
        run("rustup", "run", "1.94.0", "cargo", "build", "--manifest-path", source / "Cargo.toml", "--locked", "-p", "idevice-ffi",
            "--release", "--target", "aarch64-apple-ios", "--features", "obfuscate", env=env)
        built = ROOT / "build/PerformanceCargo/aarch64-apple-ios/release/libidevice_ffi.a"
        staged = library.with_suffix(".pending")
        shutil.copyfile(built, staged); staged.replace(library)
    destination = ROOT / "Packages/DeviceKit/IDevice.xcframework/ios-arm64/libidevice_ffi.a"
    shutil.copyfile(library, destination)
    print("Prepared pinned idevice iOS slice with RSD discovery compatibility", flush=True)

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        message = re.sub(r"https?://\S+", "<URL redacted>", str(error))[:3000]
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Performance dependency setup::" + message, flush=True)
        raise

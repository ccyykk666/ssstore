"""Build a self-contained, pinned AssppWeb TCI/WASM runtime. No account data."""
import bz2
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import urllib.request
import zlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "scripts/kbsync-manifest.json").read_text())
CACHE = ROOT / "build/KBSyncCache"
SOURCE = ROOT / "build/KBSyncSource"
RUNTIME = ROOT / "build/KBSyncRuntime"
UPDATE = "https://swcdn.apple.com/content/downloads/27/34/041-98128-A_SYPWICN3KH/5dqkl4rqgbsr18yzy61yeie9g3cmjc5hiv/OSXUpd10.9.pkg"


def verified(data, size, digest):
    return len(data) == size and hashlib.sha256(data).hexdigest() == digest


def cached_asset(spec):
    path = CACHE / spec["name"]
    return path.exists() and verified(path.read_bytes(), spec["strippedSize"], spec["strippedSha256"])


def get_range(start, end):
    request = urllib.request.Request(UPDATE, headers={"Range": f"bytes={start}-{end}", "Accept-Encoding": "identity"})
    with urllib.request.urlopen(request, timeout=60) as response:
        if response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {start}-{end}/"):
            raise ValueError("Apple server did not honor the requested asset range")
        data = response.read(end - start + 2)
    if len(data) != end - start + 1:
        raise ValueError("Incomplete or oversized Apple asset range")
    return data


def payload_extent():
    data = get_range(0, 65535)
    if data[:4] != b"xar!":
        raise ValueError("Invalid Apple XAR header")
    header_size = struct.unpack_from(">H", data, 4)[0]
    toc_size = struct.unpack_from(">Q", data, 8)[0]
    if header_size != 28 or toc_size > 65536 - header_size:
        raise ValueError("Unexpected Apple XAR TOC")
    toc = ET.fromstring(zlib.decompress(data[header_size:header_size + toc_size]))
    entries = [f for f in toc.iter("file") if f.findtext("name") == "Payload"]
    if len(entries) != 1:
        raise ValueError("Missing or ambiguous Apple payload")
    entry = entries[0].find("data")
    def number(key):
        value = entry.findtext(key)
        return int(value, 16 if value.startswith("0x") else 10)
    return header_size + toc_size + number("offset"), number("length")


def decompressed_chunks(start, end):
    decoder = bz2.BZ2Decompressor()
    incoming = b"BZh9"
    while True:
        chunk = decoder.decompress(incoming, max_length=65536)
        if chunk:
            yield chunk
        if decoder.eof:
            return
        if decoder.needs_input:
            if start >= end:
                raise ValueError("Truncated Apple bzip2 stream")
            stop = min(start + (16 << 20), end)
            incoming = get_range(start, stop - 1)
            start = stop
        else:
            incoming = b""


class Reader:
    def __init__(self, chunks):
        self.chunks, self.pending = iter(chunks), b""

    def read(self, count, keep=True):
        pieces = []
        while count:
            if not self.pending:
                self.pending = next(self.chunks)
            taken = min(count, len(self.pending))
            if keep:
                pieces.append(self.pending[:taken])
            self.pending = self.pending[taken:]
            count -= taken
        return b"".join(pieces)


def amd64_slice(data):
    magic = data[:4]
    if magic not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        return data
    wide = magic[-1] == 0xbf
    for index in range(struct.unpack_from(">I", data, 4)[0]):
        entry = 8 + index * (32 if wide else 20)
        if struct.unpack_from(">I", data, entry)[0] != 0x01000007:
            continue
        offset, size = struct.unpack_from(">QQ" if wide else ">II", data, entry + 8)
        if offset + size > len(data):
            raise ValueError("Invalid Apple architecture slice")
        return data[offset:offset + size]
    raise ValueError("Missing x86_64 Apple image")


def prepare_assets():
    if all(cached_asset(spec) for spec in MANIFEST["assets"]):
        return
    print("Extracting pinned public Apple kbsync resources", flush=True)
    offset, length = payload_extent()
    reader = Reader(decompressed_chunks(offset + 0x352f40d5, offset + length))
    reader.read(0x3a4, keep=False)
    wanted = {spec["path"]: spec for spec in MANIFEST["assets"]}
    while wanted:
        magic = reader.read(6)
        if magic == b"070707":
            header = magic + reader.read(70)
            name_size, size = int(header[59:65], 8), int(header[65:76], 8)
            alignment = 1
        elif magic == b"070701":
            header = magic + reader.read(104)
            name_size, size = int(header[94:102], 16), int(header[54:62], 16)
            alignment = 4
        else:
            raise ValueError("Invalid Apple CPIO header")
        if not 0 < name_size <= 4096:
            raise ValueError("Invalid Apple CPIO filename")
        name = reader.read(name_size).rstrip(b"\0").decode("utf-8")
        reader.read(-(len(header) + name_size) % alignment, keep=False)
        spec = wanted.get(name)
        if spec:
            if size != spec["size"]:
                raise ValueError("Unexpected Apple asset size")
            data = reader.read(size)
            if not verified(data, spec["size"], spec["sha256"]):
                raise ValueError("Apple asset integrity check failed")
            data = amd64_slice(data)
            if not verified(data, spec["strippedSize"], spec["strippedSha256"]):
                raise ValueError("Stripped Apple asset integrity check failed")
            (CACHE / spec["name"]).write_bytes(data)
            del wanted[name]
            print("Prepared " + spec["name"], flush=True)
        else:
            if name == "TRAILER!!!":
                raise ValueError("Missing required Apple resources")
            reader.read(size, keep=False)
        reader.read(-size % alignment, keep=False)


def main():
    for directory in (CACHE, SOURCE, RUNTIME):
        directory.mkdir(parents=True, exist_ok=True)
    for entry in MANIFEST["files"]:
        relative = entry["path"]
        target = SOURCE / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = target.read_bytes() if target.exists() else b""
        def digest(value):
            return hashlib.sha1(f"blob {len(value)}\0".encode() + value).hexdigest()
        if digest(data) != entry["sha"]:
            url = f'https://raw.githubusercontent.com/{MANIFEST["repository"]}/{MANIFEST["revision"]}/{relative}'
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            if digest(data) != entry["sha"]:
                raise ValueError("Upstream source integrity check failed")
            target.write_bytes(data)
    prepare_assets()
    upstream = SOURCE / "frontend/src/apple/kbsync"
    # IIFE bundling removes import.meta; bypass the unused factory URL fallback.
    engine = (upstream / "engine.ts").read_text().replace(
        "const config: Record<string, unknown> = {};",
        "const config: Record<string, unknown> = { locateFile: (name: string) => name };")
    (upstream / "engine.ts").write_text(engine)
    shutil.copy(ROOT / "scripts/kbsync-runtime.ts", upstream / "ssstore.ts")
    shutil.copy(ROOT / "scripts/kbsync-worker.ts", upstream / "ssstore-worker.ts")
    subprocess.run(["npx", "--yes", "esbuild@0.25.12", str(upstream / "ssstore.ts"), "--bundle",
                    "--format=iife", "--platform=browser", "--target=safari17", "--external:module",
                    "--outfile=" + str(RUNTIME / "runtime.js")], check=True)
    subprocess.run(["npx", "--yes", "esbuild@0.25.12", str(upstream / "ssstore-worker.ts"), "--bundle",
                    "--format=iife", "--platform=browser", "--target=safari17", "--external:module",
                    "--outfile=" + str(RUNTIME / "worker.js")], check=True)
    shutil.copy(ROOT / "scripts/kbsync-index.html", RUNTIME / "index.html")
    shutil.copy(upstream / "vendor/unicorn.wasm", RUNTIME / "unicorn.wasm")
    for spec in MANIFEST["assets"]:
        shutil.copy(CACHE / spec["name"], RUNTIME / spec["name"])
    # Include the complete corresponding interpreter source, patch and notices.
    shutil.copytree(SOURCE, RUNTIME / "sources", dirs_exist_ok=True)
    (RUNTIME / "provenance.json").write_text(json.dumps(MANIFEST, indent=2))
    print("Prepared self-contained kbsync runtime", flush=True)


if __name__ == "__main__":
    main()

"""Publish the newest successful, trusted main-branch IPA and prepare GitHub Pages."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile


def gh(*args):
    return subprocess.check_output(["gh", *map(str, args)], text=True)


def select_run(runs, repository):
    trusted = [run for run in runs if
               run.get("conclusion") == "success" and run.get("status") == "completed"
               and run.get("head_branch") == "main"
               and run.get("event") in ("push", "workflow_dispatch")
               and run.get("path") == ".github/workflows/build-ios.yml"
               and run.get("head_repository", {}).get("full_name") == repository]
    if not trusted:
        raise ValueError("No successful main-branch iOS build is available")
    return max(trusted, key=lambda run: (run["run_number"], run["run_attempt"]))


def describe_ipa(ipa):
    with zipfile.ZipFile(ipa) as archive:
        names = [name for name in archive.namelist() if name.startswith("Payload/")
                 and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(names) != 1:
            raise ValueError("IPA must contain exactly one top-level application")
        info = plistlib.loads(archive.read(names[0]))
        if info.get("CFBundleIdentifier") != "dev.personal.ssstore":
            raise ValueError("Unexpected application bundle ID")
        if archive.testzip() is not None:
            raise ValueError("IPA archive is corrupt")
    with ipa.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"version": str(info["CFBundleShortVersionString"]),
            "build": str(info["CFBundleVersion"]), "bytes": ipa.stat().st_size,
            "sha256": digest,
            "minimumOS": str(info.get("MinimumOSVersion", "17.0"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", type=Path, default=Path("build/publication"))
    args = parser.parse_args()
    repo = args.repository
    output = args.output
    # Never execute source from the downloaded artifact. Only inspect its IPA.
    response = json.loads(gh("api", f"repos/{repo}/actions/workflows/build-ios.yml/runs?branch=main&status=success&per_page=100"))
    run = select_run(response["workflow_runs"], repo)
    output.mkdir(parents=True, exist_ok=True)
    download = output / "download"
    download.mkdir(exist_ok=True)
    gh("run", "download", run["id"], "--repo", repo, "--name", "ssstore-unsigned", "--dir", download)
    packages = list(download.rglob("*.ipa"))
    if len(packages) != 1:
        raise ValueError("Expected one IPA in the build artifact")
    ipa = output / "ssstore.ipa"
    shutil.copyfile(packages[0], ipa)
    metadata = describe_ipa(ipa)
    tag = f"build-{run['run_number']}-{run['id']}-{run['run_attempt']}"
    base = f"https://github.com/{repo}/releases/download/{tag}"
    metadata.update(tag=tag, commit=run["head_sha"], run=run["run_number"],
                    builtAt=run["updated_at"], buildURL=run["html_url"],
                    downloadURL=f"{base}/ssstore.ipa", checksumURL=f"{base}/ssstore.ipa.sha256")
    site = output / "site"
    shutil.copytree("web/download", site, dirs_exist_ok=True)
    (site / ".nojekyll").touch()
    (site / "release.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    checksum = output / "ssstore.ipa.sha256"
    checksum.write_text(f"{metadata['sha256']}  ssstore.ipa\n")
    notes = output / "release-notes.md"
    notes.write_text(f"ssstore {metadata['version']}（{metadata['build']}），未签名 IPA。下载后需自行签名安装。\n\n"
                     f"- 来源提交：{run['head_sha']}\n- 构建记录：{run['html_url']}\n"
                     f"- SHA-256：`{metadata['sha256']}`\n\n"
                     "此版本由成功的主分支构建自动发布。校验文件与版本信息随安装包一起提供。\n")
    # List first: authentication/network failures must not be treated as a missing release.
    releases = json.loads(gh("api", f"repos/{repo}/releases?per_page=100"))
    existing = next((release for release in releases if release["tag_name"] == tag), None)
    if existing and existing["target_commitish"] != run["head_sha"]:
        raise ValueError("Existing release does not match the built commit")
    if not existing:
        gh("release", "create", tag, "--repo", repo, "--target", run["head_sha"], "--draft",
           "--title", f"ssstore {metadata['version']} ({metadata['build']}) · Build {run['run_number']}",
           "--notes-file", notes)
    if not existing or existing["draft"]:
        gh("release", "upload", tag, ipa, checksum, site / "release.json", "--repo", repo, "--clobber")
        gh("release", "edit", tag, "--repo", repo, "--draft=false", "--latest")
    else:
        assets = {asset["name"]: asset["size"] for asset in existing["assets"]}
        for asset in (ipa, checksum, site / "release.json"):
            if assets.get(asset.name) != asset.stat().st_size:
                raise ValueError(f"Published release asset is missing or inconsistent: {asset.name}")
        # Keep successful packages immutable; reuse them for page-only deployments.
        gh("release", "edit", tag, "--repo", repo, "--latest")
    print(f"Published {metadata['downloadURL']}")


if __name__ == "__main__":
    main()

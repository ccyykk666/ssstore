"""Publish an explicitly unverified prerelease when only simulator setup failed."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location("publication", Path(__file__).with_name("publish-download.py"))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


def validate_source(run, jobs, annotations, repository):
    if not (run.get("status") == "completed" and run.get("conclusion") == "failure"
            and run.get("head_branch") == "main" and run.get("event") in ("push", "workflow_dispatch")
            and run.get("path") == ".github/workflows/build-ios.yml"
            and run.get("head_repository", {}).get("full_name") == repository):
        raise ValueError("Candidate must come from a completed, trusted main-branch build")
    states = {job["name"]: job.get("conclusion") for job in jobs}
    if states.get("build") != "success" or states.get("checks") != "success" or states.get("native-sheet") != "failure":
        raise ValueError("Compilation and core checks must have succeeded; only the simulator job may fail")
    failures = [a["message"] for a in annotations if a.get("annotation_level") == "failure"]
    allowed = ("Native sheet probe failed while booting ",
               "Native sheet probe failed while waiting for simulator app services")
    if not any(message.startswith(allowed) and "timed out" in message for message in failures):
        raise ValueError("Failure is not a known simulator setup timeout; do not publish a candidate")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run", required=True, type=int)
    args = parser.parse_args()
    repo, run_id = args.repository, args.run
    gh = publication.gh
    run = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}"))
    jobs = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100"))["jobs"]
    native = next(job for job in jobs if job["name"] == "native-sheet")
    check_id = native["check_run_url"].rsplit("/", 1)[-1]
    annotations = json.loads(gh("api", f"repos/{repo}/check-runs/{check_id}/annotations?per_page=100"))
    validate_source(run, jobs, annotations, repo)
    output = Path("build/candidate")
    download = output / "download"
    download.mkdir(parents=True, exist_ok=True)
    gh("run", "download", run_id, "--repo", repo, "--name", "ssstore-unsigned", "--dir", download)
    packages = list(download.rglob("*.ipa"))
    if len(packages) != 1:
        raise ValueError("Expected exactly one compiled IPA")
    ipa = packages[0]
    metadata = publication.describe_ipa(ipa)
    tag = f"candidate-{metadata['build']}-{run_id}-{run['run_attempt']}"
    base = f"https://github.com/{repo}/releases/download/{tag}"
    metadata.update(tag=tag, commit=run["head_sha"], buildURL=run["html_url"],
                    downloadURL=base + "/ssstore.ipa", candidate=True,
                    uiValidation="unavailable-simulator-setup-timeout")
    manifest = output / "release.json"
    manifest.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    checksum = output / "ssstore.ipa.sha256"
    checksum.write_text(f"{metadata['sha256']}  ssstore.ipa\n")
    notes = output / "notes.md"
    notes.write_text(f"ssstore {metadata['version']}（{metadata['build']}）测试版，未签名 IPA。\n\n"
                     "核心测试、缓存保护测试及 iOS 编译通过。模拟器启动超时，未完成自动界面回归；后台安装和左滑交互仍需真机验证。\n"
                     "本测试版不替换正式版下载页，也不表示界面回归已通过。\n\n"
                     f"来源提交：{run['head_sha']}\n构建：{run['html_url']}\nSHA-256：`{metadata['sha256']}`\n")
    # Leave the stable release and Pages untouched. No failed App build or
    # actual UI assertion failure is accepted by this publication path.
    gh("release", "create", tag, ipa, checksum, manifest, "--repo", repo,
       "--target", run["head_sha"], "--prerelease", "--latest=false",
       "--title", f"ssstore {metadata['version']} ({metadata['build']}) 测试版", "--notes-file", notes)
    print("Published candidate: " + metadata["downloadURL"])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        message = publication.safe_error(str(error)).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Candidate publication::" + message, flush=True)
        raise

"""Exercise routing boundaries and real multi-commit/delete/rename git history."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("selection", Path(__file__).parents[1] / "select-ci-tests.py")
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)


class SelectionTests(unittest.TestCase):
    def test_ui_and_native_changes_do_not_repeat_library_checks(self):
        self.assertFalse(any(selection.select_checks([
            "ssstore/ContentView.swift", "ssstore/Bridge/DeviceInstaller.m",
            "Vendor/Asspp/Asspp/Interface/Setting/SettingView.swift",
        ]).values()))

    def test_each_check_tracks_its_actual_inputs(self):
        cases = {
            "Packages/UpdateCore/Sources/UpdateCore/Models.swift": {"core"},
            "Packages/UpdateCore/Package.swift": {"core"},
            "Packages/UpdateCore/Tests/UpdateCoreTests/CatalogTests.swift": {"core"},
            "Packages/LocalInstallTLS/Sources/LocalInstallTLS/LocalInstallIdentity.swift": {"installation"},
            selection.STORE + "Asspp/Backend/Installer/Installer+TLS.swift": {"installation"},
            selection.STORE + "Asspp/Backend/AppStore/StoreProtocol.swift": {"downloads"},
            selection.STORE + "Asspp/Backend/AppStore/StoreHistorySupport.swift": {"downloads"},
            selection.STORE + "Asspp/Backend/AppStore/StoreCatalogHistoryService.swift": {"downloads"},
            selection.STORE + "Resources/Tests/HistorySupportChecks.swift": {"downloads"},
            selection.STORE + "Asspp/Backend/AppStore/StoreDownloadProtocol.swift": {"downloads", "localization"},
            selection.STORE + "Asspp/App/Localizable.xcstrings": {"localization"},
            selection.STORE + "Resources/Scripts/check.downloads.sh": {"downloads", "localization"},
            "scripts/select-ci-tests.py": {"selection"},
            "ssstore/KBSyncGenerator.swift": {"kbsync"},
            "scripts/kbsync-runtime.ts": {"kbsync"},
            selection.STORE + "Asspp/Backend/AppStore/StoreDownloadService.swift": {"downloads", "kbsync"},
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual({k for k, v in selection.select_checks([path]).items() if v}, expected)

    def test_failed_commit_gap_deletion_and_rename_remain_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], stderr=subprocess.DEVNULL).decode().strip()
            def commit(message):
                git("add", "-A")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", message)
                return git("rev-parse", "HEAD")
            git("init", "-q")
            core = root / "Packages/UpdateCore/Sources/UpdateCore/Models.swift"
            core.parent.mkdir(parents=True)
            core.write_text("original")
            base = commit("last successful build")
            core.write_text("change in failed build")
            commit("failed build")
            (root / "view.swift").write_text("UI only follow-up")
            commit("UI follow-up must still test changed core")
            previous = Path.cwd()
            try:
                os.chdir(root)
                self.assertTrue(selection.select_checks(selection.changed_paths(base))["core"])
                self.assertFalse(any(selection.select_checks(selection.changed_paths("HEAD")).values()))
                core.rename(root / "moved.swift")
                commit("rename out of the watched directory")
                self.assertTrue(selection.select_checks(selection.changed_paths(base))["core"])
            finally:
                os.chdir(previous)

    def test_baseline_ignores_current_run_and_pr_merge_results(self):
        runs = [
            {"id": 3, "head_sha": "pr-head", "conclusion": "success", "event": "pull_request"},
            {"id": 2, "head_sha": "current", "conclusion": "success", "event": "push"},
            {"id": 1, "head_sha": "validated", "conclusion": "success", "event": "push"},
        ]
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self):
                import json
                return json.dumps({"workflow_runs": runs}).encode()
        env = {"GITHUB_REPOSITORY": "owner/repo", "GH_TOKEN": "test-only",
               "GITHUB_REF_NAME": "main", "GITHUB_RUN_ID": "2"}
        with patch.dict(os.environ, env, clear=True), patch.object(selection.urllib.request, "urlopen", return_value=Response()):
            self.assertEqual(selection.successful_baseline("current"), "validated")
            # Rebuilding an already-validated older commit should reuse its own success.
            runs.append({"id": 0, "head_sha": "older", "conclusion": "success", "event": "workflow_dispatch"})
            self.assertEqual(selection.successful_baseline("older"), "older")

    def test_missing_history_cannot_silently_skip_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / "outputs")
            with patch.dict(os.environ, {"GITHUB_OUTPUT": output}, clear=True), \
                    patch.object(selection, "successful_baseline", side_effect=OSError("API unavailable")), \
                    patch("sys.argv", ["select-ci-tests.py"]):
                selection.main()
            values = Path(output).read_text().splitlines()
            self.assertEqual(set(values), {f"{name}=true" for name in selection.CHECK_INPUTS})


if __name__ == "__main__":
    unittest.main()

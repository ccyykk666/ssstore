import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("publication", Path(__file__).resolve().parents[2] / "scripts/publish-download.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class PublicationTests(unittest.TestCase):
    def run_data(self, number=55, **overrides):
        run = dict(conclusion="success", status="completed", head_branch="main", event="push",
                   path=".github/workflows/build-ios.yml", head_repository={"full_name": "owner/repo"},
                   run_number=number, run_attempt=1)
        return dict(run, **overrides)

    def test_select_newest_build_even_when_completion_order_differs(self):
        self.assertEqual(publication.select_run([self.run_data(56), self.run_data(55)], "owner/repo")["run_number"], 56)

    def test_reject_untrusted_or_failed_builds(self):
        for override in [dict(conclusion="failure"), dict(head_branch="feature"), dict(event="pull_request"),
                         dict(head_repository={"full_name": "fork/repo"}), dict(path="other.yml")]:
            with self.subTest(override=override), self.assertRaises(ValueError):
                publication.select_run([self.run_data(**override)], "owner/repo")

    def test_version_comes_from_actual_ipa(self):
        with tempfile.TemporaryDirectory() as folder:
            ipa = Path(folder) / "ssstore.ipa"
            info = dict(CFBundleIdentifier="dev.personal.ssstore", CFBundleShortVersionString="1.2.3",
                        CFBundleVersion="42", MinimumOSVersion="17.0")
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/ssstore.app/Info.plist", plistlib.dumps(info))
            metadata = publication.describe_ipa(ipa)
            self.assertEqual((metadata["version"], metadata["build"]), ("1.2.3", "42"))
            self.assertEqual(metadata["bytes"], ipa.stat().st_size)
            self.assertEqual(len(metadata["sha256"]), 64)
            info["CFBundleIdentifier"] = "other.app"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/other.app/Info.plist", plistlib.dumps(info))
            with self.assertRaises(ValueError):
                publication.describe_ipa(ipa)


if __name__ == "__main__":
    unittest.main()

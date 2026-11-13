import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("candidate", Path(__file__).parents[2] / "scripts/publish-candidate.py")
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateEligibilityTests(unittest.TestCase):
    def setUp(self):
        self.repo = "owner/repo"
        self.run = dict(status="completed", conclusion="failure", head_branch="main", event="push",
                        path=".github/workflows/build-ios.yml", head_repository={"full_name": self.repo})
        self.jobs = [dict(name="build", conclusion="success"), dict(name="checks", conclusion="success"),
                     dict(name="native-sheet", conclusion="failure")]
        self.annotations = [dict(annotation_level="failure", message="Native sheet probe failed while booting iOS 26.5: timed out")]

    def test_accepts_only_known_setup_timeout_with_successful_compilation(self):
        candidate.validate_source(self.run, self.jobs, self.annotations, self.repo)
        self.jobs[0]["conclusion"] = "failure"
        with self.assertRaises(ValueError):
            candidate.validate_source(self.run, self.jobs, self.annotations, self.repo)

    def test_refuses_real_ui_failures_and_untrusted_sources(self):
        for message in ["Native sheet probe failed while interacting with sheet: status=failed", "Other error"]:
            with self.assertRaises(ValueError):
                candidate.validate_source(self.run, self.jobs, [dict(annotation_level="failure", message=message)], self.repo)
        self.run["event"] = "pull_request"
        with self.assertRaises(ValueError):
            candidate.validate_source(self.run, self.jobs, self.annotations, self.repo)

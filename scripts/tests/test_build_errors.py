import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("build_errors", Path(__file__).parents[1] / "report-build-errors.py")
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class BuildErrorTests(unittest.TestCase):
    def test_diagnostics_redact_signed_urls_and_escape_annotation_controls(self):
        line = "Source.swift:1: error: request https://example.invalid/file?secret=private failed 50%\nnext"
        result = reporter.annotation(line)
        self.assertNotIn("secret", result)
        self.assertNotIn("private", result)
        self.assertNotIn("\n", result)
        self.assertIn("50%25%0Anext", result)

    def test_normal_progress_does_not_create_failure_annotations(self):
        self.assertIsNone(reporter.annotation("CompileSwift AppModel.swift"))

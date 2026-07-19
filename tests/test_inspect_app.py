"""Standard-library tests for the application ingestion safety scanner."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "inspect_app.py"
SPEC = importlib.util.spec_from_file_location("inspect_app", MODULE_PATH)
assert SPEC and SPEC.loader
INSPECT_APP = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = INSPECT_APP
SPEC.loader.exec_module(INSPECT_APP)


class InspectApplicationTests(unittest.TestCase):
    """Cover a safe project plus the two most important refusal paths."""

    def test_valid_container_project_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "Dockerfile").write_text(
                "FROM node:22-alpine\nWORKDIR /app\nUSER node\nEXPOSE 8080\n",
                encoding="utf-8",
            )
            (root / ".dockerignore").write_text(".git\n.env*\n", encoding="utf-8")
            (root / "package.json").write_text('{"dependencies": {}}', encoding="utf-8")
            (root / "package-lock.json").write_text("{}", encoding="utf-8")

            report = INSPECT_APP.inspect_application(root)

            self.assertTrue(report.ok, report.errors)
            self.assertIn("package.json", report.manifests)

    def test_invalid_package_json_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            (root / ".dockerignore").write_text(".git\n.env*\n", encoding="utf-8")
            (root / "package.json").write_text("{broken", encoding="utf-8")

            report = INSPECT_APP.inspect_application(root)

            self.assertFalse(report.ok)
            self.assertTrue(any("Invalid package.json" in error for error in report.errors))

    def test_unignored_credential_shape_fails_without_printing_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake_key = "AKIA" + ("A" * 16)
            (root / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            (root / ".dockerignore").write_text(".git\n.env*\n", encoding="utf-8")
            (root / "settings.txt").write_text(fake_key, encoding="utf-8")

            report = INSPECT_APP.inspect_application(root)

            self.assertFalse(report.ok)
            joined_errors = " ".join(report.errors)
            self.assertIn("AWS access-key-shaped", joined_errors)
            self.assertNotIn(fake_key, joined_errors)


if __name__ == "__main__":
    unittest.main()

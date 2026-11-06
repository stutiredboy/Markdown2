"""Release must reject a wrong, absent, or changed verification artifact."""

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "verify_release_artifact.py"
SPEC = importlib.util.spec_from_file_location("verify_release_artifact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.commit = "a" * 40
        self.version = "v0.7.1"
        # These tests verify the handoff, not macOS's DMG format/signature.
        # hdiutil and codesign check the real image before it is uploaded.
        self.bytes = b"the exact package that was verified"
        self.digest = hashlib.sha256(self.bytes).hexdigest()
        (self.directory / "Markdown2.dmg").write_bytes(self.bytes)
        (self.directory / "source-commit.txt").write_text(self.commit + "\n")
        (self.directory / "package-version.txt").write_text(self.version + "\n")

    def verify(self, **overrides):
        arguments = dict(commit=self.commit, version=self.version, sha256=self.digest)
        arguments.update(overrides)
        return MODULE.verify(self.directory, **arguments)

    def test_accepts_the_verified_package_without_modifying_it(self):
        result = self.verify()
        self.assertEqual(result.read_bytes(), self.bytes)

    def test_rejects_package_from_another_commit(self):
        with self.assertRaisesRegex(ValueError, "source commit"):
            self.verify(commit="b" * 40)

    def test_rejects_package_with_another_version(self):
        with self.assertRaisesRegex(ValueError, "version differs"):
            self.verify(version="v0.7.2")

    def test_rejects_changed_downloaded_bytes(self):
        (self.directory / "Markdown2.dmg").write_bytes(b"changed package")
        with self.assertRaisesRegex(ValueError, "differs from the package"):
            self.verify()

    def test_rejects_missing_verification_output(self):
        with self.assertRaisesRegex(ValueError, "valid DMG digest"):
            self.verify(sha256="")

    def test_rejects_missing_artifact_parts(self):
        for name in ["Markdown2.dmg", "source-commit.txt", "package-version.txt"]:
            with self.subTest(name=name):
                path = self.directory / name
                data = path.read_bytes()
                path.unlink()
                with self.assertRaises(OSError):
                    self.verify()
                path.write_bytes(data)

    def test_rejects_a_tag_that_cannot_be_used_as_the_release_filename(self):
        with self.assertRaisesRegex(ValueError, "filename component"):
            self.verify(version="v1/../other")

    def test_cli_fails_before_publication_on_corruption(self):
        (self.directory / "Markdown2.dmg").write_bytes(b"corrupted")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.directory), "--commit", self.commit,
             "--version", self.version, "--sha256", self.digest],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Release artifact rejected:", result.stderr)


if __name__ == "__main__":
    unittest.main()

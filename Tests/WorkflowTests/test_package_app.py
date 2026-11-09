"""Exercise the packaging CLI with isolated files and mocked platform commands."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


class PackageAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="md2-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Scripts").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        # Substitute only the fixed OS executable path, not packaging logic.
        source = (REPO / "Scripts/package_app.sh").read_text()
        (self.root / "Scripts/package_app.sh").write_text(
            source.replace(LSREGISTER, str(self.bin / "lsregister"))
        )
        (self.root / "Resources").mkdir()
        (self.root / "Resources/AppIcon.icns").write_bytes(b"test icon")
        release = self.root / ".build/release"
        release.mkdir(parents=True)
        (release / "Markdown2").write_bytes(b"test executable")
        (release / "MD2_MD2Core.bundle").mkdir()
        (release / "MD2_MD2Core.bundle/test-resource").write_text("resource")
        self.install = self.root / "Installed.app"
        self.install.mkdir()
        (self.install / "original").write_text("keep installed app")
        wrapper = """#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['MD2_TEST_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps([name] + sys.argv[1:]) + '\\n')
if name == 'ditto':
    if os.environ.get('MD2_TEST_FAIL_COPY') == '1':
        sys.exit(1)
    shutil.copytree(sys.argv[1], sys.argv[2], dirs_exist_ok=True)
"""
        for tool in ("swift", "codesign", "ditto", "lsregister"):
            destination = self.bin / tool
            destination.write_text(wrapper)
            destination.chmod(0o755)

    def run_package(self, *arguments, ci=False, fail_copy=False):
        env = os.environ.copy()
        for key in ("CI", "GITHUB_REF_NAME", "MARKDOWN2_CODESIGN_IDENTITY"):
            env.pop(key, None)
        env.update(
            PATH=str(self.bin) + os.pathsep + env["PATH"],
            MARKDOWN2_VERSION="v1.2.3",
            MARKDOWN2_INSTALL_APP=str(self.install),
            MD2_TEST_COMMAND_LOG=str(self.log),
        )
        if ci:
            env["CI"] = "true"
        if fail_copy:
            env["MD2_TEST_FAIL_COPY"] = "1"
        return subprocess.run(
            ["bash", "Scripts/package_app.sh", *arguments], cwd=self.root,
            env=env, text=True, capture_output=True, timeout=30,
        )

    def commands(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def bundle(self):
        with (self.root / "dist/Markdown2.app/Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream)

    def test_default_build_preserves_installation_and_file_associations(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.install / "original").exists())
        self.assertFalse(any(row[0] in ("ditto", "lsregister") for row in self.commands()))
        self.assertFalse(any(row[:2] == ["swift", "-"] for row in self.commands()))
        self.assertEqual(self.bundle()["CFBundleIdentifier"], "dev.codex.md2.development")

    def test_release_build_preserves_distributed_identity_and_has_no_install_side_effects(self):
        result = self.run_package("--release", ci=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bundle()["CFBundleIdentifier"], "dev.codex.md2")
        self.assertEqual(self.bundle()["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(self.bundle()["LSMinimumSystemVersion"], "15.0")
        self.assertTrue((self.install / "original").exists())
        self.assertFalse(any(row[0] in ("ditto", "lsregister") for row in self.commands()))

    def test_install_is_explicit_and_does_not_set_default(self):
        result = self.run_package("--install", str(self.install))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.install / "Contents/Info.plist").exists())
        self.assertTrue(any(row[0] == "ditto" for row in self.commands()))
        self.assertFalse(any(row[:2] == ["swift", "-"] for row in self.commands()))

    def test_set_default_requires_explicit_install_before_build(self):
        result = self.run_package("--set-default")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])
        self.assertTrue((self.install / "original").exists())

    def test_default_handler_change_requires_both_options(self):
        result = self.run_package("--install", str(self.install), "--set-default")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(row[:2] == ["swift", "-"] for row in self.commands()))

    def test_ci_rejects_installation_before_build(self):
        result = self.run_package("--install", str(self.install), ci=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])
        self.assertTrue((self.install / "original").exists())

    def test_invalid_options_and_destinations_fail_before_build(self):
        for arguments in (("--unknown",), ("--install",),
                          ("--install", "/"), ("--install", "relative.app"),
                          ("--install", str(self.root / "dist/Markdown2.app"))):
            with self.subTest(arguments=arguments):
                result = self.run_package(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.commands(), [])
                self.assertTrue((self.install / "original").exists())

    def test_help_is_read_only(self):
        result = self.run_package("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--install", result.stdout)
        self.assertEqual(self.commands(), [])

    def test_failed_install_copy_preserves_existing_app(self):
        result = self.run_package("--install", str(self.install), fail_copy=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.install / "original").exists())
        self.assertFalse(any(row[0] == "lsregister" for row in self.commands()))
        self.assertEqual(list(self.root.glob(".md2-install.*")), [])

    def test_install_refuses_symlink_destination(self):
        alias = self.root / "Alias.app"
        alias.symlink_to(self.install, target_is_directory=True)
        result = self.run_package("--install", str(alias))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.install / "original").exists())
        self.assertEqual(self.commands(), [])


if __name__ == "__main__":
    unittest.main()

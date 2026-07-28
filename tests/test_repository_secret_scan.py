from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.scan_repository_secrets import read_only_flags, render, scan_history, scan_source


class RepositorySecretScanTests(unittest.TestCase):
    def run_git(self, root: Path, *arguments: str) -> None:
        subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True)

    def test_read_only_flags_degrade_safely_when_posix_flags_are_unavailable(self):
        with (
            mock.patch.object(os, "O_NOFOLLOW", 0, create=True),
            mock.patch.object(os, "O_CLOEXEC", 0, create=True),
        ):
            self.assertEqual(read_only_flags(), os.O_RDONLY)

    def test_source_scan_reports_path_without_echoing_value(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.run_git(root, "init", "-q")
            token = "ghp_" + "A" * 24
            (root / "token.txt").write_text(token + "\n", encoding="utf-8")
            findings = scan_source(root)
            output = render(findings)
            self.assertIn("github-token: token.txt", output)
            self.assertNotIn(token, output)

    def test_history_scan_finds_removed_runtime_secret_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.run_git(root, "init", "-q")
            self.run_git(root, "config", "user.name", "Synthetic Test")
            self.run_git(root, "config", "user.email", "synthetic@example.invalid")
            (root / "README.md").write_text("safe\n", encoding="utf-8")
            self.run_git(root, "add", "README.md")
            self.run_git(root, "commit", "-q", "-m", "safe")
            (root / ".env").write_text("SYNTHETIC_VALUE=not-real\n", encoding="utf-8")
            self.run_git(root, "add", ".env")
            self.run_git(root, "commit", "-q", "-m", "synthetic fixture")
            (root / ".env").unlink()
            self.run_git(root, "add", "-u")
            self.run_git(root, "commit", "-q", "-m", "remove fixture")

            output = render(scan_history(root))
            self.assertIn("runtime-secret-file: history:.env@", output)
            self.assertNotIn("not-real", output)


if __name__ == "__main__":
    unittest.main()

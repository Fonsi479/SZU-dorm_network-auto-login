from __future__ import annotations

import hashlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from scripts.build_windows_exe import _write_version_info
from scripts.build_macos_release import normalize_release_label as normalize_macos_release_label
from scripts.build_windows_package import (
    git_state,
    normalize_release_label as normalize_windows_release_label,
    verify_frozen_self_test,
)
from scripts.generate_sbom import git_revision
from scripts.scan_release_artifacts import scan_directory, scan_zip
from scripts.verify_windows_package import verify_executable, verify_release, verify_source


def synthetic_pe(*, subsystem: int, machine: int = 0x8664) -> bytes:
    payload = bytearray(1_000_002)
    payload[:2] = b"MZ"
    pe_offset = 0x80
    struct.pack_into("<I", payload, 0x3C, pe_offset)
    payload[pe_offset : pe_offset + 4] = b"PE\0\0"
    struct.pack_into(
        "<HHIIIHH",
        payload,
        pe_offset + 4,
        machine,
        1,
        0,
        0,
        0,
        0xF0,
        0x0022,
    )
    optional_offset = pe_offset + 24
    struct.pack_into("<H", payload, optional_offset, 0x020B)
    struct.pack_into("<H", payload, optional_offset + 68, subsystem)
    return bytes(payload)


def write_release_checksums(root: Path) -> None:
    lines = [
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}"
        for path in sorted(root.iterdir())
        if path.is_file() and path.name != "SHA256.txt"
    ]
    (root / "SHA256.txt").write_text("\n".join(lines) + "\n", encoding="ascii")


class WindowsPackagingTests(unittest.TestCase):
    def test_release_labels_are_explicit_and_cannot_impersonate_local(self):
        for normalize in (normalize_macos_release_label, normalize_windows_release_label):
            self.assertEqual(normalize(None), "")
            self.assertEqual(normalize("beta.1"), "beta.1")
            self.assertEqual(normalize("rc.2"), "rc.2")
            for invalid in ("local", "beta/1", "-rc.1", "rc.1-"):
                with self.assertRaises(ValueError):
                    normalize(invalid)

    def test_cli_version_resource_uses_cli_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "cli-version-info.txt"
            _write_version_info(
                destination,
                "2.0.0",
                (2, 0, 0),
                file_description="SZU Campus Network JSON CLI",
                internal_name="SZUCampusNetCtl",
                original_filename="szu-campus-netctl.exe",
            )
            content = destination.read_text(encoding="utf-8")
            self.assertIn("SZU Campus Network JSON CLI", content)
            self.assertIn("SZUCampusNetCtl", content)
            self.assertIn("szu-campus-netctl.exe", content)
            self.assertNotIn("OriginalFilename', 'SZU Campus Network.exe", content)

    def test_git_state_fails_closed_when_git_is_unavailable(self):
        with mock.patch(
            "scripts.build_windows_package.subprocess.run",
            side_effect=FileNotFoundError,
        ):
            self.assertEqual(git_state(Path("C:/offline-build")), ("NOASSERTION", True))

    def test_sbom_revision_is_noassertion_when_git_is_unavailable(self):
        with mock.patch(
            "scripts.generate_sbom.subprocess.run",
            side_effect=FileNotFoundError,
        ):
            self.assertEqual(git_revision(Path("C:/offline-build")), "NOASSERTION")

    def test_frozen_self_test_uses_argument_array_and_bounded_runtime(self):
        executable = Path("C:/offline-build/SZU Campus Network.exe")
        with (
            mock.patch("scripts.build_windows_package.os.name", "nt"),
            mock.patch(
                "scripts.build_windows_package.subprocess.run",
                return_value=type("Result", (), {"returncode": 0})(),
            ) as run,
        ):
            self.assertEqual(verify_frozen_self_test(executable), [])

        self.assertEqual(run.call_args.args[0], [str(executable), "--self-test"])
        self.assertEqual(run.call_args.kwargs["timeout"], 45)
        self.assertFalse(run.call_args.kwargs["check"])

    def test_source_verifier_accepts_combined_repo_without_packaging_macos(self):
        root = Path(__file__).parents[1]
        self.assertEqual(verify_source(root), [])

    def test_release_allows_only_two_executables_and_ascii_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "SZU Campus Network.exe").write_bytes(
                synthetic_pe(subsystem=2)
            )
            (root / "szu-campus-netctl.exe").write_bytes(
                synthetic_pe(subsystem=3)
            )
            (root / "README.txt").write_text("ASCII release instructions\n", encoding="ascii")
            (root / "LICENSE.txt").write_text("MIT\n", encoding="ascii")
            (root / "SECURITY.txt").write_text("security\n", encoding="ascii")
            (root / "PRIVACY.txt").write_text("privacy\n", encoding="ascii")
            (root / "CHANGELOG.txt").write_text("changes\n", encoding="ascii")
            (root / "THIRD_PARTY_NOTICES.txt").write_text("notices\n", encoding="ascii")
            (root / "SBOM.spdx.json").write_text("{}\n", encoding="ascii")
            (root / "BUILD-PROVENANCE.json").write_text("{}\n", encoding="ascii")
            write_release_checksums(root)
            self.assertEqual(verify_release(root), [])

            (root / "README.txt").write_text("tampered\n", encoding="ascii")
            failures = verify_release(root)
            self.assertTrue(any("校验失败" in failure for failure in failures))

    def test_executable_rejects_mz_only_and_wrong_subsystem(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mz_only = root / "mz-only.exe"
            mz_only.write_bytes(b"MZ" + b"\0" * 1_000_000)
            self.assertTrue(verify_executable(mz_only, expected_subsystem=2))

            console = root / "console.exe"
            console.write_bytes(synthetic_pe(subsystem=3))
            failures = verify_executable(console, expected_subsystem=2)
            self.assertTrue(any("subsystem" in failure for failure in failures))

    def test_executable_verifier_accepts_and_distinguishes_x64_and_arm64(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            x64 = root / "x64.exe"
            arm64 = root / "arm64.exe"
            x64.write_bytes(synthetic_pe(subsystem=2, machine=0x8664))
            arm64.write_bytes(synthetic_pe(subsystem=2, machine=0xAA64))

            self.assertEqual(
                verify_executable(x64, expected_subsystem=2, expected_architecture="x64"),
                [],
            )
            self.assertEqual(
                verify_executable(arm64, expected_subsystem=2, expected_architecture="arm64"),
                [],
            )
            self.assertTrue(
                verify_executable(arm64, expected_subsystem=2, expected_architecture="x64")
            )

    def test_scanner_checks_exe_bytes_in_directory_and_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "synthetic.exe"
            executable.write_bytes(b"MZ\0C:\\Users\\builder\\Documents\\secret")
            self.assertTrue(
                any("developer-path" in failure for failure in scan_directory(root))
            )

            archive = root / "synthetic.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.write(executable, executable.name)
            self.assertTrue(any("developer-path" in failure for failure in scan_zip(archive)))


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

from src.szu_netlogin import state


class PauseStateTests(unittest.TestCase):
    def test_legacy_pause_file_is_explicitly_stale(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text("2026-07-02T12:00:00+08:00\n", encoding="utf-8")

            with patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file):
                self.assertTrue(state.is_paused())
                self.assertIn("状态损坏", state.describe_pause_state())

    def test_malformed_json_is_stale_and_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text("{not-json", encoding="utf-8")
            with patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file):
                self.assertTrue(state.is_paused())
                self.assertIn("invalid_json", state.describe_pause_state())

    def test_invalid_timed_pause_is_stale_and_repairable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text(json.dumps({"mode": "until", "resume_after": "not-a-date"}), encoding="utf-8")
            with patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file):
                self.assertTrue(state.is_paused())
                self.assertIn("invalid_resume_after", state.describe_pause_state())
                state.resume()
                self.assertFalse(pause_file.exists())

    def test_next_boot_pause_is_stale_when_marker_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text(json.dumps({"mode": "until_next_boot", "boot_marker": "old-boot"}), encoding="utf-8")
            with (
                patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file),
                patch("src.szu_netlogin.state._current_boot_marker", return_value=""),
            ):
                self.assertTrue(state.is_paused())
                self.assertIn("boot_marker_unavailable", state.describe_pause_state())

    def test_expired_timed_pause_auto_resumes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text(
                json.dumps(
                    {
                        "mode": "until",
                        "resume_after": (datetime.now().astimezone() - timedelta(minutes=1)).isoformat(),
                    }
                ),
                encoding="utf-8",
            )

            with patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file):
                self.assertFalse(state.is_paused())
                self.assertFalse(pause_file.exists())

    def test_next_boot_pause_resumes_when_boot_marker_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text(
                json.dumps({"mode": "until_next_boot", "boot_marker": "old-boot"}),
                encoding="utf-8",
            )

            with (
                patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file),
                patch("src.szu_netlogin.state._current_boot_marker", return_value="new-boot"),
            ):
                self.assertFalse(state.is_paused())
                self.assertFalse(pause_file.exists())

    def test_naive_timed_pause_is_handled_without_datetime_type_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text(json.dumps({"mode": "until", "resume_after": "2000-01-01T00:00:00"}), encoding="utf-8")
            with patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file):
                self.assertFalse(state.is_paused())

    def test_next_boot_pause_refuses_unknown_boot_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            with (
                patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file),
                patch("src.szu_netlogin.state._current_boot_marker", return_value=""),
            ):
                with self.assertRaises(OSError):
                    state.pause(until_next_boot=True)
                self.assertFalse(pause_file.exists())

    def test_lock_acquisition_failure_is_stale_without_unlock_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pause_file = Path(temp_dir) / "paused"
            pause_file.write_text(json.dumps({"mode": "manual"}), encoding="utf-8")
            lock_api = state.fcntl if state.fcntl is not None else state.msvcrt
            method = "flock" if state.fcntl is not None else "locking"
            exclusive = state.fcntl.LOCK_EX if state.fcntl is not None else state.msvcrt.LK_LOCK
            with (
                patch("src.szu_netlogin.state.PAUSE_FLAG_FILE", pause_file),
                patch.object(lock_api, method, side_effect=OSError("lock unavailable")) as lock,
            ):
                self.assertTrue(state.is_paused())
                self.assertIn("lock_or_read_error", state.describe_pause_state())
                self.assertEqual(lock.call_count, 2)
                self.assertTrue(all(call.args[1] == exclusive for call in lock.call_args_list))


if __name__ == "__main__":
    unittest.main()

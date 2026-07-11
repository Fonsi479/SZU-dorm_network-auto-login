from __future__ import annotations

import unittest
from pathlib import Path


class InstallLaunchAgentScriptTests(unittest.TestCase):
    def test_optional_password_environment_variable_is_nounset_safe(self) -> None:
        script = (
            Path(__file__).resolve().parents[1] / "scripts" / "install_launchagent.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('printenv "${PASSWORD_ENV_NAME}"', script)
        self.assertNotIn('${(P)PASSWORD_ENV_NAME}', script)


if __name__ == "__main__":
    unittest.main()

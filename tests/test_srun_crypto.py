from __future__ import annotations

import json
import unittest
from pathlib import Path

from src.szu_netlogin.srun_crypto import (
    derive_login_fields,
    hmac_md5_hex,
    srun_base64,
    stable_info_json,
    xencode,
)


VECTOR_PATH = Path(__file__).parents[1] / "protocol-spec" / "vectors" / "srun-bx1.json"


class SRunCryptoVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.vector = json.loads(VECTOR_PATH.read_text(encoding="utf-8"))

    def test_public_base64_cross_check(self) -> None:
        vector = self.vector["crossChecks"]["base64"]
        self.assertEqual(srun_base64(vector["inputUtf8"].encode()), vector["expected"])

    def test_public_xencode_cross_check(self) -> None:
        vector = self.vector["crossChecks"]["xencode"]
        self.assertEqual(
            xencode(vector["messageUtf8"], vector["keyUtf8"]).hex(),
            vector["expectedHex"],
        )

    def test_complete_synthetic_login_vector(self) -> None:
        vector = self.vector["fullLoginVector"]
        fields = derive_login_fields(
            username=vector["username"],
            password=vector["credentialInput"],
            ip=vector["clientIP"],
            acid=vector["acid"],
            challenge=vector["challenge"],
            n=vector["n"],
            type_=vector["type"],
        )
        self.assertEqual(
            hmac_md5_hex(vector["credentialInput"], vector["challenge"]),
            vector["expectedHMACMD5Hex"],
        )
        self.assertEqual(
            stable_info_json(
                vector["username"], vector["credentialInput"], vector["clientIP"], vector["acid"]
            ),
            vector["expectedInfoJSON"],
        )
        self.assertEqual(fields.password, vector["expectedPasswordField"])
        self.assertEqual(fields.info, vector["expectedInfoField"])
        self.assertEqual(fields.checksum, vector["expectedChecksum"])

    def test_derived_fields_repr_is_redacted(self) -> None:
        fields = derive_login_fields(
            username="synthetic", password="not-real", ip="198.51.100.1", acid="5", challenge="abc"
        )
        self.assertEqual(repr(fields), "SRunDerivedFields(<redacted>)")
        self.assertNotIn("not-real", repr(fields))


if __name__ == "__main__":
    unittest.main()

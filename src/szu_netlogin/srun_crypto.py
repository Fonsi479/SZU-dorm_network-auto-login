"""Independent SRun BX1 field construction from the executable specification."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import struct
from dataclasses import dataclass


STANDARD_BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
SRUN_BASE64_ALPHABET = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"
_BASE64_TRANSLATION = str.maketrans(STANDARD_BASE64_ALPHABET, SRUN_BASE64_ALPHABET)


@dataclass(frozen=True, repr=False)
class SRunDerivedFields:
    password: str
    info: str
    checksum: str

    def __repr__(self) -> str:
        return "SRunDerivedFields(<redacted>)"


def hmac_md5_hex(password: str, challenge: str) -> str:
    return hmac.new(challenge.encode(), password.encode(), hashlib.md5).hexdigest()


def xencode(message: str, key: str) -> bytes:
    values = _to_uint32(message.encode("utf-8"), include_length=True)
    if not values:
        return b""
    key_words = _to_uint32(key.encode("utf-8"), include_length=False)
    key_words.extend([0] * (4 - len(key_words)))
    key_words = key_words[:4]
    count = len(values) - 1
    z = values[count]
    total = 0
    rounds = 6 + 52 // (count + 1)
    delta = 0x9E3779B9
    for _ in range(rounds):
        total = (total + delta) & 0xFFFFFFFF
        e = (total >> 2) & 3
        for index in range(count):
            y = values[index + 1]
            mixed = _mix(z, y, total, key_words[(index & 3) ^ e])
            values[index] = (values[index] + mixed) & 0xFFFFFFFF
            z = values[index]
        y = values[0]
        mixed = _mix(z, y, total, key_words[(count & 3) ^ e])
        values[count] = (values[count] + mixed) & 0xFFFFFFFF
        z = values[count]
    return b"".join(struct.pack("<I", value) for value in values)


def srun_base64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii").translate(_BASE64_TRANSLATION)


def stable_info_json(username: str, password: str, ip: str, acid: str) -> str:
    return json.dumps(
        {
            "username": username,
            "password": password,
            "ip": ip,
            "acid": acid,
            "enc_ver": "srun_bx1",
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


def derive_login_fields(
    *, username: str, password: str, ip: str, acid: str, challenge: str, n: str = "200", type_: str = "1"
) -> SRunDerivedFields:
    digest = hmac_md5_hex(password, challenge)
    info_json = stable_info_json(username, password, ip, acid)
    info = "{SRBX1}" + srun_base64(xencode(info_json, challenge))
    checksum_source = "".join(
        (
            challenge, username,
            challenge, digest,
            challenge, acid,
            challenge, ip,
            challenge, n,
            challenge, type_,
            challenge, info,
        )
    )
    return SRunDerivedFields(
        password="{MD5}" + digest,
        info=info,
        checksum=hashlib.sha1(checksum_source.encode()).hexdigest(),
    )


def _to_uint32(data: bytes, *, include_length: bool) -> list[int]:
    padding = (-len(data)) % 4
    words = list(struct.unpack(f"<{(len(data) + padding) // 4}I", data + b"\0" * padding)) if data else []
    if include_length:
        words.append(len(data))
    return words


def _mix(z: int, y: int, total: int, key: int) -> int:
    return (
        ((z >> 5) ^ ((y << 2) & 0xFFFFFFFF))
        + (((y >> 3) ^ ((z << 4) & 0xFFFFFFFF)) ^ (total ^ y))
        + (key ^ z)
    ) & 0xFFFFFFFF

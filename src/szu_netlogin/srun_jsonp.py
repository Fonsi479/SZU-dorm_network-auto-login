"""Strict JSONP decoding for SRun responses."""

from __future__ import annotations

import json
import re
from typing import Any


MAX_JSONP_BYTES = 64 * 1024
_CALLBACK = re.compile(r"[A-Za-z_$][A-Za-z0-9_.$]*")


class JSONPError(ValueError):
    error_code = "SRUN_JSONP_MALFORMED"


def decode_jsonp(payload: str | bytes, expected_callback: str) -> dict[str, Any]:
    if not _CALLBACK.fullmatch(expected_callback):
        raise JSONPError("invalid expected callback")
    if isinstance(payload, bytes):
        if len(payload) > MAX_JSONP_BYTES:
            raise JSONPError("response too large")
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            try:
                text = payload.decode("gb18030")
            except UnicodeDecodeError as exc:
                raise JSONPError("unsupported response encoding") from exc
    else:
        if len(payload.encode("utf-8")) > MAX_JSONP_BYTES:
            raise JSONPError("response too large")
        text = payload

    stripped = text.strip()
    prefix = expected_callback + "("
    if not stripped.startswith(prefix):
        raise JSONPError("callback mismatch")
    decoder = json.JSONDecoder()
    try:
        value, end = decoder.raw_decode(stripped[len(prefix) :])
    except json.JSONDecodeError as exc:
        raise JSONPError("invalid JSON object") from exc
    remainder = stripped[len(prefix) + end :]
    if not re.fullmatch(r"\s*\)\s*;?\s*", remainder):
        raise JSONPError("trailing JSONP content")
    if not isinstance(value, dict):
        raise JSONPError("JSONP payload must be one object")
    return value

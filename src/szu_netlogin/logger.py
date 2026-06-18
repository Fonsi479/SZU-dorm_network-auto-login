"""Logging helpers that avoid leaking campus-network credentials."""

from __future__ import annotations

import logging
import re
from pathlib import Path


LOG_DIR = Path.home() / "Library" / "Logs" / "szu-netlogin"
LOG_FILE = LOG_DIR / "netlogin.log"
FALLBACK_LOG_FILE = Path(__file__).resolve().parents[2] / "logs" / "netlogin.log"

LOGGER_NAME = "szu_netlogin"
LOGIN_URL_PATTERNS = (
    re.compile(r"(?i)https?://[^\s)]*/eportal/portal/login\?[^\s)]+"),
    re.compile(r"(?i)/eportal/portal/login\?[^\s)]+"),
)
SENSITIVE_PATTERNS = (
    (re.compile(r"(?i)(user_password\s*=\s*)[^&\s)]+"), r"\1***"),
    (re.compile(r"(?i)(password\s*=\s*)[^&\s)]+"), r"\1***"),
    (re.compile(r"(?i)(user_account\s*=\s*)[^&\s)]+"), r"\1***"),
    (re.compile(r'(?i)("user_password"\s*:\s*")[^"]*(")'), r"\1***\2"),
    (re.compile(r'(?i)("password"\s*:\s*")[^"]*(")'), r"\1***\2"),
    (re.compile(r'(?i)("user_account"\s*:\s*")[^"]*(")'), r"\1***\2"),
    (re.compile(r"(?i)('user_password'\s*:\s*')[^']*(')"), r"\1***\2"),
    (re.compile(r"(?i)('password'\s*:\s*')[^']*(')"), r"\1***\2"),
    (re.compile(r"(?i)('user_account'\s*:\s*')[^']*(')"), r"\1***\2"),
)


def redact_sensitive_text(text: object, password: str | None = None) -> str:
    """Return text with obvious credential fields masked."""
    value = "" if text is None else str(text)

    if password:
        value = value.replace(password, "***")

    for pattern in LOGIN_URL_PATTERNS:
        value = pattern.sub("[login_url_redacted]", value)

    for pattern, replacement in SENSITIVE_PATTERNS:
        value = pattern.sub(replacement, value)

    return value


def get_logger() -> logging.Logger:
    """Create the project logger once and write to logs/netlogin.log."""
    logger = logging.getLogger(LOGGER_NAME)
    logger.setLevel(logging.INFO)
    logger.propagate = False

    if any(isinstance(handler, logging.FileHandler) for handler in logger.handlers):
        return logger

    if _add_file_handler(logger, LOG_FILE):
        return logger

    if _add_file_handler(logger, FALLBACK_LOG_FILE):
        return logger

    if not any(isinstance(handler, logging.NullHandler) for handler in logger.handlers):
        logger.addHandler(logging.NullHandler())

    return logger


def _add_file_handler(logger: logging.Logger, log_file: Path) -> bool:
    try:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_file, encoding="utf-8")
    except OSError:
        return False

    file_handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    )
    logger.addHandler(file_handler)
    return True

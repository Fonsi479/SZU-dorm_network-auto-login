"""Logging helpers that avoid leaking campus-network credentials."""

from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta
from logging.handlers import RotatingFileHandler
from pathlib import Path

from .platform_paths import get_user_log_dir


LOG_DIR = get_user_log_dir()
LOG_FILE = LOG_DIR / "netlogin.log"
FALLBACK_LOG_FILE = Path(__file__).resolve().parents[2] / "logs" / "netlogin.log"
LOG_MAX_BYTES = 1_000_000
LOG_BACKUP_COUNT = 7
LOG_RETENTION_DAYS = 7

LOGGER_NAME = "szu_netlogin"
LOG_DATE_PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2}) ")
LOGIN_URL_PATTERNS = (
    re.compile(r"(?i)https?://[^\s)]*/eportal/portal/login\?[^\s)]+"),
    re.compile(r"(?i)/eportal/portal/login\?[^\s)]+"),
    re.compile(r"(?i)https?://[^\s)]*/cgi-bin/(?:get_challenge|srun_portal|rad_user_info)\?[^\s)]+"),
    re.compile(r"(?i)/cgi-bin/(?:get_challenge|srun_portal|rad_user_info)\?[^\s)]+"),
)
SENSITIVE_PATTERNS = (
    (
        re.compile(
            r"(?i)((?:user_password|password|user_account|username|user_name|challenge|info|chksum|checksum|cookie|authorization)\s*=\s*)[^&\s),]+"
        ),
        r"\1***",
    ),
    (
        re.compile(
            r'(?i)("(?:user_password|password|user_account|username|user_name|challenge|info|chksum|checksum|cookie|authorization)"\s*:\s*")[^"]*(")'
        ),
        r"\1***\2",
    ),
    (
        re.compile(
            r"(?i)('(?:user_password|password|user_account|username|user_name|challenge|info|chksum|checksum|cookie|authorization)'\s*:\s*')[^']*(')"
        ),
        r"\1***\2",
    ),
    (re.compile(r"\{MD5\}[0-9a-fA-F]+"), "[derived_password_redacted]"),
    (re.compile(r"\{SRBX1\}[^&\s),]+"), "[srun_info_redacted]"),
)
_DEVICE_ID_FIELD_PATTERN = re.compile(
    r"(?i)((?:[\"'])?(?:online_ip|v46ip|ss5|v4ip|olip|source_ip|"
    r"online_mac|ss4|olmac|nas_ip|wlan_user_ip|wlan_user_mac|"
    r"wlanacip|wlan_ac_ip|ac_ip|nasname|wlan_ac_name)(?:[\"'])?\s*[:=]\s*[\"']?)"
    r"[^,;\s\"'\]}]+"
)


class _RedactingFormatter(logging.Formatter):
    """Apply the same identifier filter to every persisted log record."""

    def format(self, record: logging.LogRecord) -> str:
        return redact_sensitive_text(super().format(record))


def redact_sensitive_text(text: object, password: str | None = None) -> str:
    """Return text with obvious credential fields masked."""
    value = "" if text is None else str(text)

    if password:
        value = value.replace(password, "***")

    for pattern in LOGIN_URL_PATTERNS:
        value = pattern.sub("[login_url_redacted]", value)

    for pattern, replacement in SENSITIVE_PATTERNS:
        value = pattern.sub(replacement, value)

    # Portal/session responses and exception strings may include device
    # identity fields that are not credentials.  Keep the field names and
    # surrounding structure for diagnostics, but never persist their values.
    value = _DEVICE_ID_FIELD_PATTERN.sub(r"\1[device_id_redacted]", value)

    return value


def get_logger() -> logging.Logger:
    """Create the project logger once and write to the user log file."""
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
        _trim_old_log_records(log_file)
        file_handler = RotatingFileHandler(
            log_file,
            maxBytes=LOG_MAX_BYTES,
            backupCount=LOG_BACKUP_COUNT,
            encoding="utf-8",
            delay=True,
        )
        if log_file.exists() and log_file.stat().st_size >= LOG_MAX_BYTES:
            file_handler.doRollover()
    except OSError:
        return False

    file_handler.setFormatter(
        _RedactingFormatter("%(asctime)s [%(levelname)s] %(message)s")
    )
    logger.addHandler(file_handler)
    return True


def _trim_old_log_records(log_file: Path) -> None:
    if not log_file.exists():
        return

    cutoff_date = (datetime.now() - timedelta(days=LOG_RETENTION_DAYS)).date()
    keep_record = False
    changed = False
    kept_lines: list[str] = []

    try:
        with log_file.open("r", encoding="utf-8", errors="replace") as source:
            for line in source:
                match = LOG_DATE_PATTERN.match(line)
                if match:
                    try:
                        record_date = datetime.strptime(
                            match.group(1),
                            "%Y-%m-%d",
                        ).date()
                    except ValueError:
                        record_date = None

                    if record_date is not None:
                        keep_record = record_date >= cutoff_date

                if keep_record:
                    kept_lines.append(line)
                else:
                    changed = True
    except OSError:
        return

    if not changed:
        return

    try:
        with log_file.open("w", encoding="utf-8") as target:
            target.writelines(kept_lines)
    except OSError:
        return

#!/usr/bin/env python3
"""Compatibility wrapper for the dorm Dr.COM diagnostic command."""

from __future__ import annotations

from src.szu_netlogin.diagnose import main


if __name__ == "__main__":
    raise SystemExit(main())

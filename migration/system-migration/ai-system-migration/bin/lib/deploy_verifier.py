#!/usr/bin/env python3
"""Deployment verification helpers."""
from __future__ import annotations

import hashlib
import re
import socket
from pathlib import Path
from typing import Any, Dict, List


def port_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def error_fingerprint(text: str) -> str:
    normalized = re.sub(r"\d+", "#", text.lower())
    normalized = re.sub(r"0x[0-9a-f]+", "0x#", normalized)
    normalized = re.sub(r"\s+", " ", normalized)[:2000]
    return hashlib.sha256(normalized.encode("utf-8", errors="ignore")).hexdigest()[:16]


def classify_log_error(text: str) -> Dict[str, Any]:
    rules = [
        ("port_conflict", ["address already in use", "端口", "already bound"]),
        ("jdbc_driver_missing", ["classnotfoundexception", "driver", "dmjdbc", "jdbc"]),
        ("database_connection_failed", ["connection refused", "communications link failure", "login failed", "连接失败"]),
        ("sql_incompatible", ["syntax error", "sqlsyntaxerrorexception", "不支持", "invalid column"]),
        ("permission", ["permission denied", "权限不足"]),
        ("jdk_incompatible", ["unsupported major.minor", "unsupported class file major version"]),
        ("missing_dependency", ["nosuchmethoderror", "noclassdeffounderror", "classnotfoundexception"]),
    ]
    lower = text.lower()
    for category, words in rules:
        if any(w in lower for w in words):
            return {"category": category, "fingerprint": error_fingerprint(text)}
    return {"category": "unknown", "fingerprint": error_fingerprint(text)}


def summarize_health(services: List[Dict[str, Any]]) -> Dict[str, Any]:
    ok = [s for s in services if s.get("status") == "ok"]
    bad = [s for s in services if s.get("status") != "ok"]
    return {"total": len(services), "ok": len(ok), "failed": len(bad), "failed_services": bad}

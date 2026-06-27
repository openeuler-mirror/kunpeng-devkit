#!/usr/bin/env python3
"""Java application transformation helper utilities."""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import zipfile
from pathlib import Path
from typing import Any, Dict, List


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_build_tool(source_dir: str | Path) -> Dict[str, Any]:
    p = Path(source_dir)
    if (p / "pom.xml").exists():
        return {"tool": "maven", "command": "mvn -DskipTests package"}
    if (p / "build.gradle").exists() or (p / "settings.gradle").exists():
        return {"tool": "gradle", "command": "gradle build -x test"}
    if (p / "build.xml").exists():
        return {"tool": "ant", "command": "ant"}
    return {"tool": "unknown", "command": ""}


def find_sql_and_config_files(root: str | Path) -> List[str]:
    root = Path(root)
    patterns = ["*.xml", "*.sql", "*.properties", "*.yml", "*.yaml"]
    files: List[str] = []
    for pattern in patterns:
        files.extend(str(p) for p in root.rglob(pattern) if p.is_file())
    return files


def detect_signed_archive(archive: str | Path) -> Dict[str, Any]:
    risks = []
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            upper = name.upper()
            if upper.startswith("META-INF/") and (upper.endswith(".SF") or upper.endswith(".RSA") or upper.endswith(".DSA")):
                risks.append(name)
    return {"signed": bool(risks), "signature_files": risks}


def backup_file(path: str | Path, backup_dir: str | Path) -> str:
    path = Path(path)
    backup_dir = Path(backup_dir)
    backup_dir.mkdir(parents=True, exist_ok=True)
    target = backup_dir / f"{path.name}.bak"
    shutil.copy2(path, target)
    return str(target)


def recommend_transform(source_mode: str, target_db: str = "dm") -> Dict[str, Any]:
    base = {
        "target_db": target_db,
        "actions": [
            "replace JDBC driver with DM JDBC driver",
            "rewrite datasource URL/user/password config",
            "scan MyBatis XML and SQL files",
            "rewrite incompatible SQL dialect where possible",
            "build or repackage application",
        ],
        "requires_user_confirmation": [],
    }
    if source_mode == "no-source":
        base["actions"].insert(0, "backup original Jar/WAR/EAR")
        base["actions"].insert(1, "decompile with CFR")
        base["requires_user_confirmation"].append("decompile_authorization")
    return base

#!/usr/bin/env python3
"""Default and custom route planning for Java x86 -> ARM migration."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List


def detect_component_names(scan_summary: Dict[str, Any]) -> List[str]:
    comps = scan_summary.get("components", {}).get("detected", [])
    names = []
    for c in comps:
        n = " ".join(str(c.get(k) or "") for k in ("name", "type", "path")).lower()
        names.append(n)
    return names


def default_route(scan_summary: Dict[str, Any]) -> Dict[str, Any]:
    names = detect_component_names(scan_summary)
    joined = "\n".join(names)
    route = {
        "route_id": "default-java-x86-to-arm",
        "status": "draft",
        "application_type": "java",
        "jdk": {"target": "openjdk-arm-keep-major", "reason": "默认保持源端 Java 大版本，使用 OpenJDK ARM"},
        "middleware": [],
        "route_policy": {"no_silent_fallback": True, "fallback_requires_explicit_config": True},
        "package_policy": {"local_first": True, "kunpeng_archive_second": True, "official_site_third": True, "record_url_sha256": True},
        "database": {"target": "dm", "migration_preference": "dynamic-first", "compatibility_mode": "auto-by-source-db", "auto_install": True},
        "application": {"source_preferred": True, "no_source_decompile": True, "decompile_tool": "cfr"},
        "manual_confirm_items": ["确认是否使用默认国产化迁移路线。"],
    }
    if "tomcat" in joined:
        route["middleware"].append({"source": "tomcat", "target": "tongweb", "custom_options": ["tongweb", "bes", "tomcat-arm"], "fallback_to_apache_tomcat": False, "requires_license": True})
    if "resin" in joined:
        route["middleware"].append({"source": "resin", "target": "resin-arm"})
    if "nginx" in joined:
        route["middleware"].append({"source": "nginx", "target": "nginx-arm"})
    if "redis" in joined:
        route["middleware"].append({"source": "redis", "target": "redis-arm"})
    if not route["middleware"]:
        route["middleware"].append({"source": "unknown-java-runtime", "target": "openjdk-arm"})
    return route


def write_route(route: Dict[str, Any], path: str | Path) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(route, ensure_ascii=False, indent=2), encoding="utf-8")

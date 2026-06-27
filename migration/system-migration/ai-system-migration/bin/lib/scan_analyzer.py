#!/usr/bin/env python3
"""Parse devkit_disk_scan.sh result files and infer deployment structure."""
from __future__ import annotations

import json
import os
import re
import zipfile
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass
class Candidate:
    path: str
    kind: str
    confidence: str
    reason: str


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def normalize_list(value: Any) -> List[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return list(value.values())
    return []


def infer_runtime_apps(java_runtime: Any, components: Any, files_map: Any) -> List[Dict[str, Any]]:
    apps: List[Candidate] = []
    runtimes = normalize_list(java_runtime)
    for proc in runtimes:
        if not isinstance(proc, dict):
            continue
        entry_type = str(proc.get("entry_type") or "").lower()
        main_jar = proc.get("main_jar") or proc.get("jar")
        cmd = " ".join(str(x) for x in proc.get("cmdline", [])) if isinstance(proc.get("cmdline"), list) else str(proc.get("cmdline") or "")
        sun_cmd = str(proc.get("sun_java_command") or "")
        classpath = proc.get("runtime_classpath") or proc.get("runtime_class_path") or []
        if entry_type == "jar" and main_jar:
            apps.append(Candidate(str(main_jar), "jar", "high", "running Java process entry_type=Jar"))
        elif "-cp" in cmd or "-classpath" in cmd or classpath:
            main_class = sun_cmd.split()[0] if sun_cmd else "unknown-main-class"
            apps.append(Candidate(main_class, "main-class", "medium", "running Java process uses classpath"))
            if isinstance(classpath, str):
                cp_items = classpath.split(os.pathsep)
            else:
                cp_items = list(classpath)
            for item in cp_items:
                if str(item).endswith(".jar"):
                    apps.append(Candidate(str(item), "dependency-jar", "medium", "runtime classpath dependency"))

    # Tomcat/Resin runtime packages from components.
    for comp in normalize_list(components):
        if not isinstance(comp, dict):
            continue
        ctype = str(comp.get("type") or comp.get("component") or comp.get("name") or "").lower()
        runtime_pkg = comp.get("runtime_pkg") or comp.get("runtime_package")
        runtime_conf = comp.get("runtime_conf")
        if runtime_pkg and ("tomcat" in ctype or "resin" in ctype):
            apps.append(Candidate(str(runtime_pkg), "webapp-runtime-package", "high", f"{ctype} runtime package"))
        if runtime_conf and ("tomcat" in ctype or "resin" in ctype):
            apps.append(Candidate(str(runtime_conf), "runtime-conf", "medium", f"{ctype} runtime config package"))

    # Jar/WAR/EAR candidates from files_map.
    if isinstance(files_map, dict):
        iterable = []
        for v in files_map.values():
            iterable.extend(normalize_list(v))
    else:
        iterable = normalize_list(files_map)
    for item in iterable:
        if isinstance(item, dict):
            path = item.get("path") or item.get("file")
        else:
            path = str(item)
        if path and re.search(r"\.(jar|war|ear)$", str(path), re.I):
            apps.append(Candidate(str(path), Path(str(path)).suffix[1:].lower(), "low", "application package found in files_map"))

    # Deduplicate while preserving highest rank.
    rank = {"high": 3, "medium": 2, "low": 1}
    best: Dict[str, Candidate] = {}
    for c in apps:
        old = best.get(c.path)
        if old is None or rank.get(c.confidence, 0) > rank.get(old.confidence, 0):
            best[c.path] = c
    return [asdict(c) for c in sorted(best.values(), key=lambda x: rank.get(x.confidence, 0), reverse=True)]


def infer_components(components: Any) -> Dict[str, Any]:
    running = []
    detected = []
    for comp in normalize_list(components):
        if not isinstance(comp, dict):
            continue
        name = comp.get("name") or comp.get("component") or comp.get("type") or comp.get("path") or "unknown"
        item = {
            "name": name,
            "type": comp.get("type") or comp.get("kind"),
            "version": comp.get("version"),
            "path": comp.get("path") or comp.get("home") or comp.get("base"),
            "running": bool(comp.get("running") or comp.get("in_use") or comp.get("tomcat_in_use") or comp.get("resin_in_use")),
            "runtime_conf": comp.get("runtime_conf"),
            "runtime_pkg": comp.get("runtime_pkg"),
        }
        detected.append(item)
        if item["running"]:
            running.append(item)
    return {"detected": detected, "running": running}


def find_source_candidates(scan_root: Path, max_results: int = 50) -> List[Dict[str, Any]]:
    markers = {".git", "pom.xml", "build.gradle", "settings.gradle", "Dockerfile", "Jenkinsfile"}
    candidates: Dict[Path, Dict[str, Any]] = {}
    if not scan_root.exists():
        return []
    for root, dirs, files in os.walk(scan_root):
        # avoid huge collected binary/artifact folders
        parts = set(Path(root).parts)
        if {"target", "node_modules", ".m2", ".gradle"} & parts:
            continue
        names = set(dirs) | set(files)
        hit = markers & names
        if "src" in dirs and (Path(root) / "src" / "main" / "java").exists():
            hit.add("src/main/java")
        if hit:
            p = Path(root)
            score = len(hit)
            candidates[p] = {
                "path": str(p),
                "markers": sorted(hit),
                "confidence": "high" if score >= 3 else "medium" if score == 2 else "low",
            }
        if len(candidates) >= max_results:
            break
    return sorted(candidates.values(), key=lambda x: {"high": 3, "medium": 2, "low": 1}.get(x["confidence"], 0), reverse=True)


def analyze(scan_dir: str | Path) -> Dict[str, Any]:
    scan_dir = Path(scan_dir)
    components = load_json(scan_dir / "components.json", [])
    files_map = load_json(scan_dir / "files_map.json", {})
    java_runtime = load_json(scan_dir / "java_runtime.json", [])
    specified_pack = load_json(scan_dir / "specified_pack.json", {})

    result = {
        "phase": "scan-analysis",
        "status": "success" if (scan_dir / "components.json").exists() else "partially_success",
        "scan_dir": str(scan_dir),
        "runtime_apps": infer_runtime_apps(java_runtime, components, files_map),
        "components": infer_components(components),
        "source_candidates": find_source_candidates(scan_dir),
        "specified_pack": specified_pack,
        "manual_confirm_items": [],
        "risks": [],
    }
    if not result["runtime_apps"]:
        result["manual_confirm_items"].append("无法从 java_runtime.json 明确判断实际运行 Jar/WAR/EAR，需要用户确认应用包路径。")
    if not result["source_candidates"]:
        result["manual_confirm_items"].append("未发现可靠源码路径，需要用户提供源码目录或确认无源码反编译路线。")
    return result

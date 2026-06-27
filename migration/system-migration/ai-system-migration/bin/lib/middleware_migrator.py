#!/usr/bin/env python3
"""Middleware migration planner/executor.

This module enforces route fidelity: if the route says Tomcat -> TongWeb, the
phase must resolve TongWeb and license. It must not silently install Apache
Tomcat unless fallback_to_apache_tomcat=true is explicitly configured.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tarfile
import zipfile
from pathlib import Path
from typing import Any, Dict, List

from .package_resolver import resolve_package, sha256_file


def _read_json(path: str | Path) -> Dict[str, Any]:
    p = Path(path)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _route_middleware(config: Dict[str, Any]) -> List[Dict[str, Any]]:
    workspace = Path(config.get("workspace", "/opt/ai-system-migration"))
    route = _read_json(workspace / "state" / "route.json").get("route_plan", {})
    if not route:
        route_path = workspace / "config" / "route_plan.yaml"
        if route_path.exists():
            try:
                import yaml  # type: ignore
                route = yaml.safe_load(route_path.read_text(encoding="utf-8")) or {}
            except Exception:
                try:
                    route = json.loads(route_path.read_text(encoding="utf-8"))
                except Exception:
                    route = {}
    return route.get("middleware", []) or []


def _extract_archive(package_path: Path, dest: Path) -> Dict[str, Any]:
    dest.mkdir(parents=True, exist_ok=True)
    lower = package_path.name.lower()
    if lower.endswith((".tar.gz", ".tgz", ".tar")):
        mode = "r:gz" if lower.endswith((".tar.gz", ".tgz")) else "r:"
        with tarfile.open(package_path, mode) as tf:
            tf.extractall(dest)
        return {"status": "extracted", "method": "tar", "dest": str(dest)}
    if lower.endswith(".zip"):
        with zipfile.ZipFile(package_path) as zf:
            zf.extractall(dest)
        return {"status": "extracted", "method": "zip", "dest": str(dest)}
    return {"status": "unsupported_archive", "reason": f"{package_path.name} 不是可直接解压的包"}


def plan_tongweb(config: Dict[str, Any], execute: bool = False) -> Dict[str, Any]:
    mw = config.get("middleware", {})
    workspace = Path(config.get("workspace", "/opt/ai-system-migration"))
    download = bool(mw.get("download_missing_packages", True))
    pkg = resolve_package("tongweb", config, download=download)
    lic = resolve_package("tongweb-license", config, download=False)
    result: Dict[str, Any] = {
        "component": "tongweb",
        "route_enforced": "tomcat->tongweb",
        "fallback_to_apache_tomcat": bool(mw.get("fallback_to_apache_tomcat", False)),
        "package_resolution": pkg,
        "license_resolution": lic,
        "status": "planned",
        "installed": False,
        "package_sources": [],
        "risks": [],
    }
    if pkg.get("status") not in {"found", "downloaded"}:
        result.update({
            "status": "waiting_input",
            "reason": "route_plan 要求 Tomcat->东方通，但未找到可用 TongWeb 安装包。禁止静默降级到 Apache Tomcat。",
        })
        if result["fallback_to_apache_tomcat"]:
            result["reason"] += " 当前已显式允许 fallback_to_apache_tomcat，可由上层单独执行 Apache Tomcat 降级路径。"
        return result
    if lic.get("status") not in {"found", "downloaded"}:
        result.update({
            "status": "waiting_input",
            "reason": "route_plan 要求 Tomcat->东方通，但未找到 TongWeb license。请将 license.dat/*.lic 放入 /opt/ai-system-migration/packages/tongweb。",
        })
        return result
    selected = pkg["selected"]
    package_path = Path(selected["path"])
    install_root = Path(mw.get("install_root", "/opt/middleware"))
    install_dir = Path(mw.get("tongweb", {}).get("install_dir", str(install_root / "tongweb")))
    result["package_sources"].append({
        "component": "tongweb",
        "path": str(package_path),
        "sha256": selected.get("sha256") or sha256_file(package_path),
        "source_type": selected.get("source_type"),
        "url": selected.get("url", ""),
    })
    result["package_sources"].append({
        "component": "tongweb-license",
        "path": lic["selected"].get("path"),
        "sha256": lic["selected"].get("sha256"),
        "source_type": lic["selected"].get("source_type"),
    })
    result["install_dir"] = str(install_dir)
    if not execute:
        result["status"] = "ready_to_install"
        result["next_command"] = "python3 bin/ai_system_migration.py phase middleware --config <config> --execute"
        return result
    lower = package_path.name.lower()
    if lower.endswith((".tar.gz", ".tgz", ".tar", ".zip")):
        install_result = _extract_archive(package_path, install_dir)
        if install_result.get("status") == "extracted":
            license_dest = install_dir / "license"
            license_dest.mkdir(parents=True, exist_ok=True)
            shutil.copy2(lic["selected"]["path"], license_dest / Path(lic["selected"]["path"]).name)
            result.update({"status": "success", "installed": True, "install_result": install_result})
        else:
            result.update({"status": "waiting_input", "reason": install_result.get("reason"), "install_result": install_result})
        return result
    # Vendor .bin/.sh installers vary. Execute only with configured silent args.
    silent_args = mw.get("tongweb", {}).get("silent_install_args", [])
    if lower.endswith((".bin", ".sh")) and silent_args:
        os.chmod(package_path, os.stat(package_path).st_mode | 0o111)
        cmd = [str(package_path)] + [str(x) for x in silent_args]
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        result.update({
            "status": "success" if proc.returncode == 0 else "failed",
            "installed": proc.returncode == 0,
            "command": cmd,
            "returncode": proc.returncode,
            "log_tail": proc.stdout[-4000:],
        })
        return result
    result.update({
        "status": "waiting_input",
        "reason": "已找到 TongWeb 包，但该包需要厂商静默安装参数。请在 middleware.tongweb.silent_install_args 中配置后重试，或提供 tar.gz/zip 免安装包。",
    })
    return result


def plan_generic(component: str, target: str, config: Dict[str, Any], execute: bool = False) -> Dict[str, Any]:
    download = bool(config.get("middleware", {}).get("download_missing_packages", True))
    package_type = target.replace("-arm", "")
    pkg = resolve_package(package_type, config, download=download)
    result: Dict[str, Any] = {
        "component": component,
        "target": target,
        "package_resolution": pkg,
        "status": "ready_to_install" if pkg.get("status") in {"found", "downloaded"} else "waiting_input",
        "installed": False,
        "risks": [],
    }
    if result["status"] == "waiting_input":
        result["reason"] = f"未找到 {target} 安装包。"
        return result
    if not execute:
        return result
    # For generic components we only perform source/binary package extraction.
    p = Path(pkg["selected"]["path"])
    install_root = Path(config.get("middleware", {}).get("install_root", "/opt/middleware"))
    dest = install_root / target
    extract = _extract_archive(p, dest)
    result.update({
        "status": "success" if extract.get("status") == "extracted" else "waiting_input",
        "installed": extract.get("status") == "extracted",
        "install_result": extract,
    })
    return result


def migrate_middleware(config: Dict[str, Any], execute: bool = False) -> Dict[str, Any]:
    route_items = _route_middleware(config)
    if not route_items:
        route_items = []
        dr = config.get("default_route", {})
        if dr.get("tomcat"):
            route_items.append({"source": "tomcat", "target": dr.get("tomcat")})
    installed: List[Dict[str, Any]] = []
    blocked: List[Dict[str, Any]] = []
    for item in route_items:
        source = str(item.get("source", "")).lower()
        target = str(item.get("target", "")).lower()
        if source == "tomcat" and target in {"tongweb", "东方通"}:
            r = plan_tongweb(config, execute=execute)
        elif target in {"bes", "宝兰德"}:
            r = {"component": "bes", "status": "waiting_input", "reason": "宝兰德为自定义路线，需补充 BES 安装包、license 和静默安装参数。"}
        else:
            r = plan_generic(source or target, target, config, execute=execute)
        if r.get("status") in {"success", "ready_to_install"}:
            installed.append(r)
        else:
            blocked.append(r)
    return {
        "phase": "middleware",
        "status": "success" if not blocked else "waiting_input",
        "executed": execute,
        "installed_or_ready": installed,
        "blocked": blocked,
        "policy": {
            "no_silent_fallback": True,
            "fallback_to_apache_tomcat": bool(config.get("middleware", {}).get("fallback_to_apache_tomcat", False)),
        },
    }

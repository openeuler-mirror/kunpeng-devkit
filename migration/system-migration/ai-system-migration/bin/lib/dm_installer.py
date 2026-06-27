#!/usr/bin/env python3
"""DM installation and migration planning helpers.

The implementation is best-effort and conservative. It can install from common
DM Linux packages when silent-install parameters are available, create an
instance with dminit, register a systemd service and import a SQL dump. When the
exact vendor package layout is unknown, it stops with an actionable waiting_input
result instead of pretending success.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

from .database_migrator import find_dts_cli, source_compatibility
from .package_resolver import resolve_package, sha256_file


def run(cmd: List[str], timeout: int = 600, user: Optional[str] = None) -> Dict[str, Any]:
    actual_cmd = cmd
    if user:
        actual_cmd = ["su", "-", user, "-c", " ".join(_quote(x) for x in cmd)]
    proc = subprocess.run(actual_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    return {"command": actual_cmd, "returncode": proc.returncode, "log_tail": proc.stdout[-6000:]}


def _quote(s: str) -> str:
    return "'" + str(s).replace("'", "'\\''") + "'"


def dm_installed(config: Dict[str, Any]) -> Dict[str, Any]:
    db = config.get("database", {})
    homes = db.get("dm_home_candidates", []) or ["/opt/dmdbms", "/dm8", "/opt/dm8"]
    found_homes = []
    for h in homes:
        p = Path(os.path.expandvars(str(h)))
        if p.exists():
            found_homes.append(str(p))
    dts = find_dts_cli(db.get("dts_cli_candidates", []))
    port = int(db.get("instance_port", 5236))
    port_open = False
    for cmd in (["bash", "-lc", f"ss -lntp 2>/dev/null | grep -q ':{port} '"] , ["bash", "-lc", f"netstat -lntp 2>/dev/null | grep -q ':{port} '"]):
        try:
            if subprocess.run(cmd).returncode == 0:
                port_open = True
                break
        except Exception:
            pass
    return {"dm_home_found": found_homes, "dts_cli": dts, "port": port, "port_open": port_open, "installed": bool(found_homes or dts or port_open)}


def find_dm_package(config: Dict[str, Any], download: bool = True) -> Dict[str, Any]:
    return resolve_package("dm", config, download=download)


def _ensure_dmdba(config: Dict[str, Any]) -> Dict[str, Any]:
    service_user = config.get("database", {}).get("service_user", "dmdba")
    check = subprocess.run(["id", service_user], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check.returncode == 0:
        return {"status": "exists", "user": service_user}
    group = config.get("database", {}).get("service_group", "dinstall")
    results = []
    results.append(run(["bash", "-lc", f"getent group {group} >/dev/null || groupadd {group}"]))
    results.append(run(["bash", "-lc", f"useradd -g {group} -m -s /bin/bash {service_user}"]))
    status = "success" if all(r["returncode"] == 0 for r in results) else "failed"
    return {"status": status, "user": service_user, "group": group, "results": results}


def _locate_installer_from_iso(iso: Path) -> Dict[str, Any]:
    mount_dir = Path(tempfile.mkdtemp(prefix="dm_iso_"))
    mount = run(["mount", "-o", "loop", str(iso), str(mount_dir)])
    if mount["returncode"] != 0:
        shutil.rmtree(mount_dir, ignore_errors=True)
        return {"status": "failed", "mount": mount}
    for pattern in ["**/DMInstall.bin", "**/*DMInstall*.bin", "**/*.bin"]:
        hits = list(mount_dir.glob(pattern))
        if hits:
            return {"status": "mounted", "mount_dir": str(mount_dir), "installer": str(hits[0])}
    return {"status": "installer_not_found", "mount_dir": str(mount_dir)}


def _locate_installer(package_path: Path) -> Dict[str, Any]:
    lower = package_path.name.lower()
    if lower.endswith(".iso"):
        return _locate_installer_from_iso(package_path)
    if lower.endswith(".bin"):
        return {"status": "found", "installer": str(package_path), "mount_dir": ""}
    if lower.endswith((".tar.gz", ".tgz", ".zip")):
        extract_dir = Path(tempfile.mkdtemp(prefix="dm_pkg_"))
        if lower.endswith(".zip"):
            import zipfile
            with zipfile.ZipFile(package_path) as zf:
                zf.extractall(extract_dir)
        else:
            import tarfile
            with tarfile.open(package_path, "r:gz") as tf:
                tf.extractall(extract_dir)
        for pattern in ["**/DMInstall.bin", "**/*DMInstall*.bin", "**/*.bin"]:
            hits = list(extract_dir.glob(pattern))
            if hits:
                return {"status": "found", "installer": str(hits[0]), "extract_dir": str(extract_dir), "mount_dir": ""}
        return {"status": "installer_not_found", "extract_dir": str(extract_dir), "mount_dir": ""}
    return {"status": "unsupported", "reason": f"unsupported DM package: {package_path}"}


def _generate_auto_install_xml(config: Dict[str, Any], path: Path) -> Path:
    db = config.get("database", {})
    install_dir = db.get("install_dir", "/opt/dmdbms")
    service_user = db.get("service_user", "dmdba")
    key = db.get("license_key", "")
    # DM silent XML differs slightly between releases. This common skeleton is
    # used only when the vendor installer accepts -q <xml>; otherwise installer
    # output will be captured and the phase will stop with details.
    text = f'''<?xml version="1.0"?>
<DATABASE>
  <LANGUAGE>en</LANGUAGE>
  <TIME_ZONE>+08:00</TIME_ZONE>
  <KEY>{key}</KEY>
  <INSTALL_TYPE>0</INSTALL_TYPE>
  <INSTALL_PATH>{install_dir}</INSTALL_PATH>
  <INIT_DB>n</INIT_DB>
  <CREATE_DB_SERVICE>n</CREATE_DB_SERVICE>
  <STARTUP_DB_SERVICE>n</STARTUP_DB_SERVICE>
  <DB_USER>{service_user}</DB_USER>
</DATABASE>
'''
    path.write_text(text, encoding="utf-8")
    return path


def _compat_mode_value(source_type: str) -> int:
    # DM commonly uses 4 for MySQL compatibility, 2 for Oracle compatibility in many deployments.
    mapping = {"mysql": 4, "oracle": 2, "sqlserver": 3, "mssql": 3, "db2": 5}
    return mapping.get(source_type.lower(), 0)


def _init_instance(config: Dict[str, Any]) -> Dict[str, Any]:
    db = config.get("database", {})
    install_dir = Path(db.get("install_dir", "/opt/dmdbms"))
    service_user = db.get("service_user", "dmdba")
    data_dir = Path(db.get("data_dir", "/opt/dmdata"))
    db_name = db.get("database_name", "DMDB")
    instance_name = db.get("instance_name", "DMSERVER")
    port = str(db.get("instance_port", 5236))
    dminit = install_dir / "bin" / "dminit"
    if not dminit.exists():
        return {"status": "waiting_input", "reason": f"dminit not found: {dminit}"}
    data_dir.mkdir(parents=True, exist_ok=True)
    shutil.chown(data_dir, user=service_user, group=db.get("service_group", "dinstall"))
    cmd = [str(dminit), f"PATH={data_dir}", f"DB_NAME={db_name}", f"INSTANCE_NAME={instance_name}", f"PORT_NUM={port}"]
    # Optional params.
    if "case_sensitive" in db:
        cmd.append(f"CASE_SENSITIVE={1 if db.get('case_sensitive') else 0}")
    if db.get("charset"):
        cmd.append(f"CHARSET={db.get('charset')}")
    result = run(cmd, timeout=600, user=service_user)
    dm_ini = data_dir / db_name / "dm.ini"
    if result["returncode"] == 0 and dm_ini.exists():
        source_type = str(config.get("database", {}).get("source_type", "mysql"))
        compat = _compat_mode_value(source_type)
        if compat:
            text = dm_ini.read_text(encoding="utf-8", errors="ignore")
            if re.search(r"^\s*COMPATIBLE_MODE\s*=", text, flags=re.M):
                text = re.sub(r"^\s*COMPATIBLE_MODE\s*=.*$", f"COMPATIBLE_MODE = {compat}", text, flags=re.M)
            else:
                text += f"\nCOMPATIBLE_MODE = {compat}\n"
            dm_ini.write_text(text, encoding="utf-8")
        return {"status": "success", "result": result, "dm_ini": str(dm_ini), "compatibility_mode": compat}
    return {"status": "failed", "result": result, "dm_ini": str(dm_ini)}


def _register_service(config: Dict[str, Any], dm_ini: str) -> Dict[str, Any]:
    db = config.get("database", {})
    install_dir = Path(db.get("install_dir", "/opt/dmdbms"))
    instance_name = db.get("instance_name", "DMSERVER")
    script = install_dir / "script" / "root" / "dm_service_installer.sh"
    if not script.exists():
        return {"status": "waiting_input", "reason": f"service installer not found: {script}"}
    result = run([str(script), "-t", "dmserver", "-dm_ini", dm_ini, "-p", instance_name], timeout=300)
    service = f"DmService{instance_name}"
    start = run(["systemctl", "start", service], timeout=120) if result["returncode"] == 0 else {"skipped": True}
    enable = run(["systemctl", "enable", service], timeout=120) if result["returncode"] == 0 else {"skipped": True}
    return {"status": "success" if result["returncode"] == 0 else "failed", "service": service, "register": result, "start": start, "enable": enable}


def install_dm(config: Dict[str, Any], execute: bool = False) -> Dict[str, Any]:
    db = config.get("database", {})
    installed = dm_installed(config)
    pkg = find_dm_package(config, download=bool(db.get("download_missing_packages", True)))
    result: Dict[str, Any] = {
        "phase": "database-install",
        "target_database": "dm",
        "installed_before": installed,
        "package_resolution": pkg,
        "executed": execute,
        "status": "prepared",
        "risks": [],
    }
    if installed.get("installed"):
        result.update({"status": "already_installed", "dts_cli": installed.get("dts_cli")})
        return result
    if pkg.get("status") not in {"found", "downloaded"}:
        result.update({
            "status": "waiting_input",
            "reason": "目标机未安装 DM，且未找到 DM8 ARM 安装包。请将 dm8_*.iso / DMInstall.bin / dm8_*.tar.gz 放入 /opt/ai-system-migration/packages/dm，或配置可直接下载 URL。",
        })
        return result
    selected = pkg["selected"]
    package_path = Path(selected["path"])
    result["package_source"] = {
        "path": str(package_path),
        "url": selected.get("url", ""),
        "sha256": selected.get("sha256") or sha256_file(package_path),
        "source_type": selected.get("source_type"),
    }
    installer = _locate_installer(package_path)
    result["installer_resolution"] = installer
    if installer.get("status") not in {"found", "mounted"}:
        result.update({"status": "waiting_input", "reason": "已找到 DM 包，但未能定位 DMInstall.bin，请检查包格式。"})
        return result
    if not execute:
        result.update({
            "status": "ready_to_install",
            "next_command": "python3 bin/ai_system_migration.py phase database-install --config <config> --execute",
        })
        return result
    user_result = _ensure_dmdba(config)
    result["ensure_dmdba"] = user_result
    if user_result.get("status") not in {"exists", "success"}:
        result.update({"status": "failed", "reason": "创建/复用 dmdba 用户失败"})
        return result
    installer_path = Path(installer["installer"])
    os.chmod(installer_path, os.stat(installer_path).st_mode | 0o111)
    auto_xml = Path(config.get("workspace", "/opt/ai-system-migration")) / "workspace" / "db_migration" / "dm_auto_install.xml"
    auto_xml.parent.mkdir(parents=True, exist_ok=True)
    _generate_auto_install_xml(config, auto_xml)
    install_cmd = [str(installer_path), "-q", str(auto_xml)]
    install_result = run(install_cmd, timeout=int(db.get("install_timeout_seconds", 1800)))
    result["install_result"] = install_result
    # Clean up ISO mount after installer execution later.
    if install_result["returncode"] != 0:
        result.update({
            "status": "failed",
            "reason": "DM 静默安装命令执行失败。请根据 log_tail 调整 database.silent_install_xml 或安装参数。",
        })
        _cleanup_installer(installer)
        return result
    init = _init_instance(config)
    result["init_instance"] = init
    if init.get("status") != "success":
        result.update({"status": "failed", "reason": "DM 实例初始化失败"})
        _cleanup_installer(installer)
        return result
    service = _register_service(config, init["dm_ini"])
    result["service"] = service
    _cleanup_installer(installer)
    final = dm_installed(config)
    result["installed_after"] = final
    result["dts_cli"] = final.get("dts_cli")
    result["status"] = "success" if service.get("status") == "success" else "partial"
    return result


def _cleanup_installer(installer: Dict[str, Any]) -> None:
    mount_dir = installer.get("mount_dir")
    if mount_dir:
        subprocess.run(["umount", mount_dir], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        shutil.rmtree(mount_dir, ignore_errors=True)


def import_sql_dump(config: Dict[str, Any], dump_path: str | Path) -> Dict[str, Any]:
    db = config.get("database", {})
    install_dir = Path(db.get("install_dir", "/opt/dmdbms"))
    disql = install_dir / "bin" / "disql"
    if not disql.exists():
        return {"status": "waiting_input", "reason": f"disql not found: {disql}"}
    dba_user = db.get("dba_username", "SYSDBA")
    dba_pass = db.get("dba_password", "SYSDBA")
    host = db.get("host", "127.0.0.1")
    port = db.get("instance_port", db.get("port", 5236))
    dump_path = Path(dump_path)
    if not dump_path.exists():
        return {"status": "waiting_input", "reason": f"SQL dump not found: {dump_path}"}
    conn = f"{dba_user}/{dba_pass}@{host}:{port}"
    cmd = [str(disql), conn, f"`{dump_path}`"]
    result = run(cmd, timeout=int(db.get("import_timeout_seconds", 1800)))
    return {"status": "success" if result["returncode"] == 0 else "failed", "dump_path": str(dump_path), "result": result}

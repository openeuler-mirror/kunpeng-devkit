#!/usr/bin/env python3
"""AI System Migration orchestrator skeleton.

This script is intentionally conservative. It creates the workspace, records
phase state, parses scan results, generates route plans and reports. Destructive
operations must be implemented behind explicit confirmations in real projects.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import shlex
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

# Allow running from the package directory.
THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

from lib.interaction_bus import InteractionBus, redact
from lib.scan_analyzer import analyze as analyze_scan
from lib.route_planner import default_route, write_route
from lib.database_migrator import find_dts_cli, dts_summary, generate_dts_xml
from lib.dm_installer import install_dm, import_sql_dump, dm_installed
from lib.middleware_migrator import migrate_middleware
from lib.package_resolver import resolution_report_for
from lib.report_writer import write_report, write_json

DEFAULT_WORKSPACE = "/opt/ai-system-migration"


def load_yaml_or_json(path: str | Path) -> Dict[str, Any]:
    path = Path(path)
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".json":
        return json.loads(text)
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text)
        return data or {}
    except Exception:
        # Minimal fallback for the top-level workspace key.
        data: Dict[str, Any] = {}
        for line in text.splitlines():
            if line.strip().startswith("workspace:"):
                data["workspace"] = line.split(":", 1)[1].strip()
        return data



def deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def load_config(config_path: str | Path, credentials_path: str | Path | None = None) -> Dict[str, Any]:
    config = load_yaml_or_json(config_path)
    cred_path = credentials_path or config.get("credentials_file") or config.get("credentials", {}).get("file")
    if cred_path:
        creds = load_yaml_or_json(cred_path)
        # Keep credentials in a dedicated namespace but also expose selected database defaults
        # to helpers that operate on config["database"]. Reports/logs are redacted by save_phase.
        config["credentials"] = creds
        target_dbs = creds.get("target_databases") or []
        if target_dbs:
            dm = next((x for x in target_dbs if str(x.get("type", "")).lower() == "dm"), target_dbs[0])
            config.setdefault("database", {})
            for src, dst in [("host", "host"), ("port", "instance_port"), ("database", "database_name"), ("dba_username", "dba_username"), ("dba_password", "dba_password"), ("schema", "target_schema"), ("username", "target_username"), ("password", "target_password")]:
                if dm.get(src) not in (None, "") and config["database"].get(dst) in (None, ""):
                    config["database"][dst] = dm.get(src)
        source_dbs = creds.get("source_databases") or []
        if source_dbs:
            sdb = source_dbs[0]
            config.setdefault("database", {})
            if config["database"].get("source_type") in (None, ""):
                config["database"]["source_type"] = sdb.get("type")
    return config

def save_phase(workspace: str | Path, phase: str, data: Dict[str, Any]) -> None:
    workspace = Path(workspace)
    state_dir = workspace / "state"
    logs_dir = workspace / "logs"
    state_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    phase_path = state_dir / f"{phase}.json"
    phase_path.write_text(json.dumps(redact(data), ensure_ascii=False, indent=2), encoding="utf-8")
    log_record = {"ts": int(time.time()), "phase": phase, "data": redact(data)}
    with (logs_dir / "execution-log.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(log_record, ensure_ascii=False) + "\n")


def load_phase(workspace: str | Path, phase: str) -> Dict[str, Any]:
    p = Path(workspace) / "state" / f"{phase}.json"
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def init_workspace(workspace: str | Path) -> None:
    workspace = Path(workspace)
    for sub in [
        "workspace/source_scan", "workspace/transfer", "workspace/target_install",
        "workspace/db_migration", "workspace/app_transform", "workspace/deploy_verify",
        "workspace/reports", "config", "logs", "state", "packages"
    ]:
        (workspace / sub).mkdir(parents=True, exist_ok=True)
    print(f"Workspace initialized: {workspace}")



def _ssh_base(config: Dict[str, Any]) -> List[str]:
    source = config.get("source", {})
    ssh = source.get("ssh", {})
    host = ssh.get("host") or source.get("host")
    user = ssh.get("username") or ssh.get("user") or "root"
    port = int(ssh.get("port") or 22)
    if not host:
        return []
    cmd = ["ssh", "-p", str(port), "-o", "StrictHostKeyChecking=no"]
    key = ssh.get("private_key_path")
    if key:
        cmd.extend(["-i", str(key)])
    cmd.append(f"{user}@{host}")
    return cmd


def _scp_base(config: Dict[str, Any]) -> List[str]:
    source = config.get("source", {})
    ssh = source.get("ssh", {})
    port = int(ssh.get("port") or 22)
    cmd = ["scp", "-P", str(port), "-o", "StrictHostKeyChecking=no"]
    key = ssh.get("private_key_path")
    if key:
        cmd.extend(["-i", str(key)])
    return cmd


def _remote_addr(config: Dict[str, Any], remote_path: str) -> str:
    source = config.get("source", {})
    ssh = source.get("ssh", {})
    host = ssh.get("host") or source.get("host")
    user = ssh.get("username") or ssh.get("user") or "root"
    return f"{user}@{host}:{remote_path}"


def build_local_scan_command(config: Dict[str, Any], script: str | None = None, output_dir: str | None = None) -> List[str]:
    source = config.get("source", {})
    script = script or source.get("scan_script", "/opt/devkit/devkit_disk_scan.sh")
    scan_roots = source.get("scan_roots") or ["/"]
    output_dir = output_dir or source.get("output_dir") or str(Path(config.get("workspace", DEFAULT_WORKSPACE)) / "workspace" / "source_scan")
    cmd = ["bash", script, "-o", output_dir, "-l", str(source.get("log_level", "info")), "-j", str(source.get("concurrency", 4))]
    for d in scan_roots:
        cmd.extend(["-d", str(d)])
    if source.get("resume", True):
        cmd.append("--resume")
    if source.get("background", False):
        cmd.append("--background")
    dyn = source.get("dynamic_version_probe", {})
    if dyn.get("enabled") is True:
        cmd.append("--dynamic-version-probe")
    for p in source.get("specified_pack_paths", []) or []:
        cmd.extend(["-F", str(p)])
    return cmd


def build_remote_scan_plan(config: Dict[str, Any]) -> Dict[str, Any]:
    source = config.get("source", {})
    workspace = Path(config.get("workspace", DEFAULT_WORKSPACE))
    remote_workspace = source.get("remote_workspace", "/opt/ai-system-migration-source")
    remote_bin = f"{remote_workspace}/bin"
    remote_output = source.get("remote_output_dir", f"{remote_workspace}/source_scan_output")
    remote_script = source.get("remote_scan_script", f"{remote_bin}/devkit_disk_scan.sh")
    local_script = source.get("scan_script_local") or source.get("scan_script", str(workspace / "packages" / "devkit_disk_scan.sh"))
    local_collect_dir = source.get("output_dir") or str(workspace / "workspace" / "source_scan")
    ssh_cmd = _ssh_base(config)
    if not ssh_cmd:
        return {"status": "waiting_input", "reason": "source.ssh.host is required for remote_ssh mode"}
    mkdir_cmd = ssh_cmd + [f"mkdir -p {shlex.quote(remote_bin)} {shlex.quote(remote_output)}"]
    upload_cmd = _scp_base(config) + [str(local_script), _remote_addr(config, remote_script)]
    chmod_cmd = ssh_cmd + [f"chmod +x {shlex.quote(remote_script)}"]
    scan_cmd_inner = " ".join(shlex.quote(x) for x in build_local_scan_command(config, script=remote_script, output_dir=remote_output))
    run_cmd = ssh_cmd + [scan_cmd_inner]
    fetch_cmd = _scp_base(config) + ["-r", _remote_addr(config, remote_output.rstrip("/") + "/"), local_collect_dir]
    return {
        "status": "planned",
        "local_script": str(local_script),
        "remote_workspace": remote_workspace,
        "remote_scan_script": remote_script,
        "remote_output_dir": remote_output,
        "local_collect_dir": local_collect_dir,
        "commands": {
            "remote_mkdir": mkdir_cmd,
            "upload_scan_script": upload_cmd,
            "remote_chmod": chmod_cmd,
            "remote_run_scan": run_cmd,
            "fetch_result": fetch_cmd,
        },
    }


def run_remote_scan(config: Dict[str, Any]) -> Dict[str, Any]:
    plan = build_remote_scan_plan(config)
    if plan.get("status") != "planned":
        return plan
    local_script = Path(plan["local_script"])
    if not local_script.exists():
        return {"status": "waiting_input", "reason": f"local scan script not found on target ARM: {local_script}"}
    Path(plan["local_collect_dir"]).mkdir(parents=True, exist_ok=True)
    results = []
    for name in ["remote_mkdir", "upload_scan_script", "remote_chmod", "remote_run_scan", "fetch_result"]:
        cmd = plan["commands"][name]
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        results.append({"step": name, "returncode": proc.returncode, "log_tail": proc.stdout[-4000:]})
        if proc.returncode != 0:
            return {"status": "failed", "failed_step": name, "plan": plan, "results": results}
    return {"status": "success", "plan": plan, "results": results}

def phase_source_scan(config: Dict[str, Any], dry_run: bool = True) -> Dict[str, Any]:
    workspace = config.get("workspace", DEFAULT_WORKSPACE)
    bus = InteractionBus(workspace)
    source = config.get("source", {})
    execution_mode = source.get("execution_mode", "remote_ssh")
    script = Path(source.get("scan_script", "/opt/devkit/devkit_disk_scan.sh"))
    if os.geteuid() != 0:
        result = {"phase": "source-scan", "status": "failed", "reason": "target ARM side root required"}
        save_phase(workspace, "source-scan", result)
        return result
    dyn = source.get("dynamic_version_probe", {})
    if dyn.get("require_confirm", True) and dyn.get("enabled") is not True:
        bus.add_task({
            "task_id": "source-dynamic-version-probe-confirm",
            "phase": "source-scan",
            "type": "confirmation",
            "blocking_scope": "dynamic_version_probe_only",
            "default_action": "skip_dynamic_probe",
            "question": "是否允许执行只读版本探测命令，例如 --version/-version/-v？",
            "options": ["allow", "skip"],
            "expires_policy": "use_default_if_safe"
        })
    dbdump = source.get("collect_database_dump", {})
    if dbdump.get("enabled") and dbdump.get("require_confirm", True):
        bus.add_task({
            "task_id": "source-db-static-export-confirm",
            "phase": "source-scan",
            "type": "confirmation",
            "blocking_scope": "database_static_export",
            "default_action": "skip_export_until_confirmed",
            "question": "是否允许在源端导出数据库 SQL/dump 文件？",
            "options": ["allow", "skip"],
            "expires_policy": "manual"
        })
    if execution_mode == "remote_ssh":
        plan = build_remote_scan_plan(config)
        result = {
            "phase": "source-scan",
            "execution_mode": "remote_ssh",
            "status": "dry_run" if dry_run else "running",
            "scan_dir": source.get("scan_roots", ["/"]),
            "output_dir": source.get("output_dir"),
            "remote_scan_plan": plan,
            "manual_confirm_items": list(bus.pending_tasks()),
        }
        if dry_run:
            save_phase(workspace, "source-scan", result)
            return result
        remote_result = run_remote_scan(config)
        result.update(remote_result)
        save_phase(workspace, "source-scan", result)
        return result

    cmd = build_local_scan_command(config)
    result = {
        "phase": "source-scan",
        "execution_mode": "local_source",
        "status": "dry_run" if dry_run else "running",
        "scan_dir": source.get("scan_roots", ["/"]),
        "output_dir": source.get("output_dir"),
        "command": cmd,
        "manual_confirm_items": list(bus.pending_tasks()),
    }
    if dry_run:
        save_phase(workspace, "source-scan", result)
        return result
    if not script.exists():
        result.update({"status": "waiting_input", "reason": f"scan script not found: {script}"})
        save_phase(workspace, "source-scan", result)
        return result
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    result["returncode"] = proc.returncode
    result["status"] = "success" if proc.returncode == 0 else "failed"
    result["log_tail"] = proc.stdout[-8000:]
    save_phase(workspace, "source-scan", result)
    return result


def phase_scan_analysis(config: Dict[str, Any]) -> Dict[str, Any]:
    workspace = config.get("workspace", DEFAULT_WORKSPACE)
    scan_dir = config.get("source", {}).get("output_dir") or str(Path(workspace) / "workspace" / "source_scan")
    result = analyze_scan(scan_dir)
    save_phase(workspace, "scan-analysis", result)
    return result


def phase_route(config: Dict[str, Any]) -> Dict[str, Any]:
    workspace = config.get("workspace", DEFAULT_WORKSPACE)
    analysis = load_phase(workspace, "scan-analysis")
    route = default_route(analysis)
    route_path = Path(workspace) / "config" / "route_plan.yaml"
    write_route(route, route_path)
    bus = InteractionBus(workspace)
    bus.add_task({
        "task_id": "route-confirm-001",
        "phase": "route",
        "type": "confirmation",
        "blocking_scope": "middleware_install_and_database_migration",
        "default_action": "use_default_route",
        "question": "是否确认使用默认国产化迁移路线？默认：OpenJDK ARM、Tomcat->东方通、Resin->Resin ARM、数据库->DM。",
        "options": ["confirm", "customize", "skip"],
        "expires_policy": "use_default_if_safe"
    })
    result = {"phase": "route", "status": "draft", "route_plan_path": str(route_path), "route_plan": route}
    save_phase(workspace, "route", result)
    return result


def phase_database_prepare(config: Dict[str, Any]) -> Dict[str, Any]:
    workspace = config.get("workspace", DEFAULT_WORKSPACE)
    db_cfg = config.get("database", {})
    dts_cli = find_dts_cli(db_cfg.get("dts_cli_candidates", []))
    sample_job = {
        "name": "ai-system-migration-dts-job",
        "migration_mode": "full",
        "source": {"type": "mysql", "host": "SOURCE_DB_HOST", "port": 3306, "database": "SOURCE_DB", "schema": "SOURCE_SCHEMA", "username": "SOURCE_USER"},
        "target": {"host": "127.0.0.1", "port": 5236, "database": "TARGET_DB", "schema": "TARGET_SCHEMA", "username": "TARGET_USER"},
        "objects": {"mode": "schema", "include": ["SOURCE_SCHEMA"]},
    }
    xml = generate_dts_xml(sample_job)
    dts_xml_path = Path(workspace) / "workspace" / "db_migration" / "dm_dts_job.draft.xml"
    dts_xml_path.parent.mkdir(parents=True, exist_ok=True)
    dts_xml_path.write_text(xml, encoding="utf-8")
    summary = dts_summary(sample_job, dts_cli)
    result = {"phase": "database", "status": "prepared", "dts_cli": dts_cli or "not-found", "dts_xml_draft": str(dts_xml_path), "dts_summary": summary}
    save_phase(workspace, "database", result)
    return result



def phase_middleware(config: Dict[str, Any], dry_run: bool = True) -> Dict[str, Any]:
    workspace = config.get("workspace", DEFAULT_WORKSPACE)
    result = migrate_middleware(config, execute=not dry_run)
    save_phase(workspace, "middleware", result)
    return result


def phase_package_resolve(config: Dict[str, Any], dry_run: bool = True) -> Dict[str, Any]:
    workspace = config.get("workspace", DEFAULT_WORKSPACE)
    packages = config.get("package_resolution", {}).get("required_packages") or ["tongweb", "tongweb-license", "dm"]
    result = {
        "phase": "package-resolve",
        "status": "success",
        "download": not dry_run,
        "packages": resolution_report_for(packages, config, download=not dry_run),
    }
    if any(v.get("status") in {"waiting_input", "download_failed"} for v in result["packages"].values()):
        result["status"] = "waiting_input"
    save_phase(workspace, "package-resolve", result)
    return result


def phase_database_install(config: Dict[str, Any], dry_run: bool = True) -> Dict[str, Any]:
    workspace = config.get("workspace", DEFAULT_WORKSPACE)
    result = install_dm(config, execute=not dry_run)
    save_phase(workspace, "database-install", result)
    return result


def phase_database_migration(config: Dict[str, Any], dry_run: bool = True) -> Dict[str, Any]:
    workspace = Path(config.get("workspace", DEFAULT_WORKSPACE))
    db_status = dm_installed(config)
    dump_candidates = [
        workspace / "workspace" / "db_migration" / "ry_dump.sql",
        workspace / "workspace" / "db_migration" / "source_dump.sql",
    ]
    dump_path = next((p for p in dump_candidates if p.exists()), None)
    result: Dict[str, Any] = {"phase": "database-migration", "dm_status": db_status, "dry_run": dry_run}
    if not db_status.get("installed"):
        result.update({"status": "waiting_input", "reason": "DM 未安装，不能执行数据库迁移。请先执行 database-install。"})
    elif dump_path and not dry_run:
        result.update(import_sql_dump(config, dump_path))
    elif dump_path:
        result.update({"status": "ready_to_import", "dump_path": str(dump_path), "next_command": "python3 bin/ai_system_migration.py phase database-migration --config <config> --execute"})
    else:
        result.update({"status": "waiting_input", "reason": "未找到静态 SQL dump；如走 DTS 动态迁移，请使用 database-prepare 生成的 XML 和 dts_cmd_run.sh。"})
    save_phase(workspace, "database-migration", result)
    return result

def phase_report(config: Dict[str, Any]) -> Dict[str, Any]:
    workspace = Path(config.get("workspace", DEFAULT_WORKSPACE))
    data = {
        "status": "draft",
        "source_scan": load_phase(workspace, "source-scan"),
        "scan_analysis": load_phase(workspace, "scan-analysis"),
        "route_plan": load_phase(workspace, "route").get("route_plan", {}),
        "middleware": load_phase(workspace, "middleware"),
        "database": load_phase(workspace, "database"),
        "application_transform": load_phase(workspace, "app-transform"),
        "deploy_verify": load_phase(workspace, "deploy-verify"),
        "risks": [],
        "manual_confirm_items": list(InteractionBus(workspace).pending_tasks()),
    }
    report_dir = config.get("report", {}).get("output_dir") or str(workspace / "workspace" / "reports")
    paths = write_report(report_dir, data)
    result = {"phase": "report", "status": "success", "reports": paths}
    save_phase(workspace, "report", result)
    return result


def cmd_init(args: argparse.Namespace) -> None:
    init_workspace(args.workspace)


def cmd_run(args: argparse.Namespace) -> None:
    config = load_config(args.config, getattr(args, "credentials", None))
    config.setdefault("workspace", DEFAULT_WORKSPACE)
    init_workspace(config["workspace"])
    # In a real execution, set dry_run=False only after confirmation.
    print(json.dumps(phase_source_scan(config, dry_run=args.dry_run), ensure_ascii=False, indent=2))
    print(json.dumps(phase_scan_analysis(config), ensure_ascii=False, indent=2))
    print(json.dumps(phase_route(config), ensure_ascii=False, indent=2))
    print(json.dumps(phase_package_resolve(config, dry_run=args.dry_run), ensure_ascii=False, indent=2))
    print(json.dumps(phase_middleware(config, dry_run=args.dry_run), ensure_ascii=False, indent=2))
    print(json.dumps(phase_database_prepare(config), ensure_ascii=False, indent=2))
    print(json.dumps(phase_database_install(config, dry_run=args.dry_run), ensure_ascii=False, indent=2))
    print(json.dumps(phase_database_migration(config, dry_run=args.dry_run), ensure_ascii=False, indent=2))
    print(json.dumps(phase_report(config), ensure_ascii=False, indent=2))


def cmd_phase(args: argparse.Namespace) -> None:
    config = load_config(args.config, getattr(args, "credentials", None))
    config.setdefault("workspace", DEFAULT_WORKSPACE)
    init_workspace(config["workspace"])
    mapping = {
        "source-scan": lambda: phase_source_scan(config, dry_run=args.dry_run),
        "scan-analysis": lambda: phase_scan_analysis(config),
        "route": lambda: phase_route(config),
        "package-resolve": lambda: phase_package_resolve(config, dry_run=args.dry_run),
        "middleware": lambda: phase_middleware(config, dry_run=args.dry_run),
        "database-prepare": lambda: phase_database_prepare(config),
        "database-install": lambda: phase_database_install(config, dry_run=args.dry_run),
        "database-migration": lambda: phase_database_migration(config, dry_run=args.dry_run),
        "report": lambda: phase_report(config),
    }
    if args.name not in mapping:
        raise SystemExit(f"Unsupported phase: {args.name}")
    print(json.dumps(mapping[args.name](), ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description="AI System Migration Skill orchestrator")
    sub = parser.add_subparsers(required=True)

    p_init = sub.add_parser("init")
    p_init.add_argument("--workspace", default=DEFAULT_WORKSPACE)
    p_init.set_defaults(func=cmd_init)

    p_run = sub.add_parser("run")
    p_run.add_argument("--config", required=True)
    p_run.add_argument("--credentials", help="Optional credentials.yaml path. Values are redacted in state/report logs.")
    p_run.add_argument("--dry-run", dest="dry_run", action="store_true", default=True, help="Only print planned actions and write state; default true.")
    p_run.add_argument("--execute", dest="dry_run", action="store_false", help="Execute SSH/SCP/local commands after confirmations are satisfied.")
    p_run.set_defaults(func=cmd_run)

    p_phase = sub.add_parser("phase")
    p_phase.add_argument("name", choices=["source-scan", "scan-analysis", "route", "package-resolve", "middleware", "database-prepare", "database-install", "database-migration", "report"])
    p_phase.add_argument("--config", required=True)
    p_phase.add_argument("--credentials", help="Optional credentials.yaml path. Values are redacted in state/report logs.")
    p_phase.add_argument("--dry-run", dest="dry_run", action="store_true", default=True)
    p_phase.add_argument("--execute", dest="dry_run", action="store_false")
    p_phase.set_defaults(func=cmd_phase)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

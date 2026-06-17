#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PHP Application x86-to-ARM Deployment Executor
Target: openEuler 22.03 aarch64, PHP 7.0.33, php-fpm + nginx

This script is designed to be called by a Skill/Agent. It performs real deployment
steps and produces detailed logs and reports. It does not uninstall packages or
remove existing system components automatically.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import fnmatch
import gzip
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import textwrap
import time
import zipfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PHP_VERSION = "7.0.33"
DEFAULT_BASE_DIR = Path("/opt/migration")
DEFAULT_PACKAGES_DIR = DEFAULT_BASE_DIR / "packages"
DEFAULT_WORK_DIR = DEFAULT_BASE_DIR / "work"
DEFAULT_LOG_DIR = DEFAULT_BASE_DIR / "logs"
DEFAULT_REPORT_DIR = DEFAULT_BASE_DIR / "reports"
DEFAULT_SCRIPT_DIR = DEFAULT_BASE_DIR / "scripts"
DEFAULT_RUNTIME_DIR = DEFAULT_BASE_DIR / "runtime"
DEFAULT_PHP_PREFIX = Path(f"/opt/php_{PHP_VERSION}")
DEFAULT_PHP_SYMLINK = Path("/opt/php")
DEFAULT_APP_DEPLOY_DIR = Path("/opt/php-app")
DEFAULT_FPM_LISTEN = "127.0.0.1:9000"
DEFAULT_PORT_CANDIDATES = [80, 8080, 8081, 8082]
OFFICIAL_PHP_URLS = [
    f"https://www.php.net/distributions/php-{PHP_VERSION}.tar.gz",
    f"https://museum.php.net/php7/php-{PHP_VERSION}.tar.gz",
]

COMMON_BUILD_PACKAGES = [
    "gcc", "gcc-c++", "make", "autoconf", "automake", "libtool", "bison", "re2c",
    "tar", "gzip", "unzip", "wget", "curl", "findutils", "procps-ng", "psmisc",
    "libxml2-devel", "openssl-devel", "curl-devel", "zlib-devel", "bzip2-devel",
    "libjpeg-devel", "libpng-devel", "freetype-devel", "sqlite-devel", "readline-devel",
    "gettext-devel", "libXpm-devel", "libxslt-devel", "libicu-devel", "libzip-devel",
]

# PHP 7.0 configure flags. Some flags may fail on newer distros if development
# packages are missing. The executor retries with a reduced optional set and
# records the fallback clearly in the report.
PHP_CONFIGURE_FLAGS_BASE = [
    "--prefix={prefix}",
    "--with-config-file-path={prefix}/etc",
    "--with-config-file-scan-dir={prefix}/etc/conf.d",
    "--enable-fpm",
    "--with-fpm-user={fpm_user}",
    "--with-fpm-group={fpm_group}",
    "--enable-mbstring",
    "--with-mysqli=mysqlnd",
    "--with-pdo-mysql=mysqlnd",
    "--with-openssl",
    "--with-zlib",
    "--with-curl",
    "--enable-bcmath",
    "--enable-sockets",
    "--enable-pcntl",
    "--enable-soap",
    "--enable-calendar",
    "--enable-exif",
    "--enable-opcache",
    "--with-readline",
    "--with-gettext",
]

PHP_CONFIGURE_FLAGS_OPTIONAL = [
    "--enable-zip",
    "--with-bz2",
    "--with-gd",
    "--with-jpeg-dir=/usr",
    "--with-png-dir=/usr",
    "--with-freetype-dir=/usr",
    "--enable-intl",
    "--with-xsl",
]

TEXT_EXTENSIONS = {
    ".php", ".inc", ".env", ".ini", ".conf", ".config", ".txt", ".json", ".xml",
    ".yml", ".yaml", ".properties", ".sql", ".md", ".htaccess",
}
CONFIG_FILE_HINTS = [
    ".env", "config.php", "database.php", "application/database.php", "config/database.php",
    "app.php", "cache.php", "redis.php", "db.php", "settings.php", "parameters.yml",
]


class DeployError(Exception):
    pass


class Executor:
    def __init__(self, config: Dict[str, Any], dry_run: bool = False) -> None:
        self.config = config
        self.dry_run = dry_run
        self.started_at = _dt.datetime.now()
        self.timestamp = self.started_at.strftime("%Y%m%d_%H%M%S")
        self.base_dir = Path(config["paths"]["base_dir"])
        self.packages_dir = Path(config["paths"]["packages_dir"])
        self.work_dir = Path(config["paths"]["work_dir"])
        self.log_dir = Path(config["paths"]["log_dir"])
        self.report_dir = Path(config["paths"]["report_dir"])
        self.script_dir = Path(config["paths"]["script_dir"])
        self.runtime_dir = Path(config["paths"]["runtime_dir"])
        self.php_prefix = Path(config["php"]["install_prefix"])
        self.php_symlink = Path(config["php"].get("symlink", str(DEFAULT_PHP_SYMLINK)))
        self.app_deploy_dir = Path(config["app"]["deploy_dir"])
        self.service_name = config["php"].get("service_name", f"php-fpm-{PHP_VERSION}.service")
        self.action_log: List[str] = []
        self.warnings: List[str] = []
        self.failures: List[str] = []
        self.disabled_php_flags: List[str] = []
        self.installed_packages: List[str] = []
        self.created_files: List[str] = []
        self.backups: List[str] = []
        self.system_info: Dict[str, str] = {}
        self.final_nginx_port: Optional[int] = None
        self.final_web_root: Optional[str] = None
        self.final_http_status: Optional[str] = None
        self.scan_findings: List[Dict[str, Any]] = []
        self.download_attempts: List[Dict[str, str]] = []
        self.log_file = self.log_dir / f"php_arm_migration_{self.timestamp}.log"
        self.report_md = self.report_dir / f"php_app_migration_report_{self.timestamp}.md"
        self.report_json = self.report_dir / f"php_app_migration_report_{self.timestamp}.json"
        self.rpm_before = self.log_dir / "rpm_before.txt"
        self.rpm_after = self.log_dir / "rpm_after.txt"
        self.installed_pkg_file = self.report_dir / "installed_packages.txt"

    def log(self, message: str) -> None:
        line = f"[{_dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
        print(line, flush=True)
        self.action_log.append(line)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        with self.log_file.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def warn(self, message: str) -> None:
        self.warnings.append(message)
        self.log(f"[WARN] {message}")

    def fail(self, message: str) -> None:
        self.failures.append(message)
        self.log(f"[FAIL] {message}")

    def run(self, cmd: str, cwd: Optional[Path] = None, check: bool = True, timeout: Optional[int] = None) -> subprocess.CompletedProcess:
        self.log(f"$ {cmd}" + (f"  # cwd={cwd}" if cwd else ""))
        if self.dry_run:
            return subprocess.CompletedProcess(cmd, 0, "", "")
        proc = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            shell=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        if proc.stdout:
            self._append_raw_log(proc.stdout)
        if proc.stderr:
            self._append_raw_log(proc.stderr)
        if check and proc.returncode != 0:
            raise DeployError(f"Command failed({proc.returncode}): {cmd}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
        return proc

    def _append_raw_log(self, text: str) -> None:
        self.log_dir.mkdir(parents=True, exist_ok=True)
        with self.log_file.open("a", encoding="utf-8", errors="ignore") as f:
            for line in text.splitlines():
                f.write(f"    {line}\n")

    def prepare_dirs(self) -> None:
        for d in [self.base_dir, self.packages_dir, self.work_dir, self.log_dir, self.report_dir, self.script_dir, self.runtime_dir]:
            d.mkdir(parents=True, exist_ok=True)
        self.log("Prepared migration directories.")

    def precheck(self) -> None:
        self.log("Starting environment precheck.")
        if os.geteuid() != 0:
            raise DeployError("This executor must run as root.")

        uname = self.run("uname -m", check=False).stdout.strip()
        self.system_info["arch"] = uname
        if uname not in ("aarch64", "arm64"):
            self.warn(f"Current architecture is {uname}; expected aarch64/arm64.")

        os_release = Path("/etc/os-release")
        if os_release.exists():
            content = os_release.read_text(encoding="utf-8", errors="ignore")
            self.system_info["os_release"] = content.replace("\n", "; ")[:1000]
            if "openEuler" not in content:
                self.warn("/etc/os-release does not look like openEuler.")
            if "22.03" not in content:
                self.warn("openEuler version is not detected as 22.03. Continuing with best effort.")
        else:
            self.warn("/etc/os-release not found.")

        self.system_info["whoami"] = self.run("whoami", check=False).stdout.strip()
        self.system_info["kernel"] = self.run("uname -a", check=False).stdout.strip()
        self.system_info["disk"] = self.run("df -h /opt || df -h", check=False).stdout.strip()
        self.system_info["memory"] = self.run("free -h", check=False).stdout.strip()
        self.snapshot_rpm("before")

    def snapshot_rpm(self, phase: str) -> None:
        target = self.rpm_before if phase == "before" else self.rpm_after
        self.run(f"rpm -qa | sort > {shq(target)}", check=False)
        self.log(f"RPM snapshot saved: {target}")

    def diff_rpm(self) -> None:
        self.snapshot_rpm("after")
        if self.rpm_before.exists() and self.rpm_after.exists():
            self.run(f"comm -13 {shq(self.rpm_before)} {shq(self.rpm_after)} > {shq(self.installed_pkg_file)}", check=False)
            if self.installed_pkg_file.exists():
                self.installed_packages = [x.strip() for x in self.installed_pkg_file.read_text(encoding="utf-8", errors="ignore").splitlines() if x.strip()]

    def package_manager(self) -> str:
        if shutil.which("yum"):
            return "yum"
        if shutil.which("dnf"):
            return "dnf"
        raise DeployError("Neither yum nor dnf is available.")

    def install_dependencies(self) -> None:
        self.log("Installing PHP build dependencies with yum/dnf first, then offline RPMs if needed.")
        pm = self.package_manager()
        pkgs = " ".join(COMMON_BUILD_PACKAGES)
        proc = self.run(f"{pm} install -y {pkgs}", check=False, timeout=1800)
        if proc.returncode != 0:
            self.warn("Online dependency installation failed. Trying offline RPM installation from /opt/migration/packages/.")
            self.try_offline_rpms()
        else:
            self.log("Build dependencies installation completed or already satisfied.")

    def try_offline_rpms(self) -> None:
        pm = self.package_manager()
        rpms = sorted(str(p) for p in self.packages_dir.glob("*.rpm"))
        if not rpms:
            self.warn(f"No offline RPM packages found in {self.packages_dir}.")
            return
        cmd = f"{pm} localinstall -y " + " ".join(shq(x) for x in rpms)
        proc = self.run(cmd, check=False, timeout=1800)
        if proc.returncode != 0:
            self.warn("Offline RPM installation failed. Missing dependencies may still exist.")
        else:
            self.log("Offline RPM installation completed.")

    def find_php_source(self) -> Optional[Path]:
        explicit = self.config["php"].get("source_package", "")
        if explicit:
            p = Path(explicit)
            if p.exists():
                return p
        default = self.packages_dir / f"php-{PHP_VERSION}.tar.gz"
        if default.exists():
            return default
        for pattern in [f"php-{PHP_VERSION}*.tar.gz", f"php-{PHP_VERSION}*.tgz"]:
            matches = sorted(self.packages_dir.glob(pattern))
            if matches:
                return matches[0]
        return None

    def download_php_source(self) -> Path:
        target = self.packages_dir / f"php-{PHP_VERSION}.tar.gz"
        found = self.find_php_source()
        if found:
            self.log(f"Using existing PHP source package: {found}")
            return found
        self.log("PHP source package not found locally. Trying official download URLs.")
        for url in OFFICIAL_PHP_URLS:
            if shutil.which("curl"):
                cmd = f"curl -fL --connect-timeout 15 --retry 2 -o {shq(target)} {shq(url)}"
            elif shutil.which("wget"):
                cmd = f"wget -O {shq(target)} {shq(url)}"
            else:
                self.warn("Neither curl nor wget is available for downloading PHP source.")
                break
            proc = self.run(cmd, check=False, timeout=900)
            self.download_attempts.append({"url": url, "returncode": str(proc.returncode)})
            if proc.returncode == 0 and target.exists() and target.stat().st_size > 1024:
                self.log(f"Downloaded PHP source package: {target}")
                return target
        manual_msg = (
            f"Failed to download PHP {PHP_VERSION}. Please manually download php-{PHP_VERSION}.tar.gz "
            f"from {OFFICIAL_PHP_URLS[0]} or {OFFICIAL_PHP_URLS[1]} and upload it to {target}."
        )
        raise DeployError(manual_msg)

    def detect_fpm_user(self) -> Tuple[str, str]:
        if user_exists("nginx"):
            return "nginx", "nginx"
        if not user_exists("www"):
            self.run("useradd -r -s /sbin/nologin www", check=False)
            self.created_files.append("system user: www")
        return "www", "www"

    def php_installed_with_correct_version(self) -> bool:
        php_bin = self.php_prefix / "bin" / "php"
        if not php_bin.exists():
            return False
        proc = self.run(f"{shq(php_bin)} -v", check=False)
        return proc.returncode == 0 and f"PHP {PHP_VERSION}" in (proc.stdout + proc.stderr)

    def backup_path(self, path: Path) -> Optional[Path]:
        if not path.exists() and not path.is_symlink():
            return None
        if path.is_dir() and not any(path.iterdir()):
            self.log(f"Existing path is empty; will reuse it: {path}")
            return None
        backup = Path(str(path) + f".bak_{self.timestamp}")
        self.log(f"Backing up {path} to {backup}")
        if self.dry_run:
            return backup
        if backup.exists():
            raise DeployError(f"Backup target already exists: {backup}")
        shutil.move(str(path), str(backup))
        self.backups.append(str(backup))
        return backup

    def build_php(self) -> None:
        if self.php_prefix.exists() and self.php_installed_with_correct_version():
            self.log(f"PHP {PHP_VERSION} already exists in {self.php_prefix}; skipping PHP compilation.")
            self.ensure_php_symlink()
            self.configure_php_fpm()
            return
        self.backup_path(self.php_prefix)
        src = self.download_php_source()
        extract_root = self.work_dir / f"php-src-{self.timestamp}"
        extract_root.mkdir(parents=True, exist_ok=True)
        self.log(f"Extracting PHP source package {src} to {extract_root}")
        with tarfile.open(src, "r:gz") as tar:
            safe_extract_tar(tar, extract_root)
        src_dir_candidates = sorted(extract_root.glob(f"php-{PHP_VERSION}*"))
        if not src_dir_candidates:
            raise DeployError(f"Cannot find extracted PHP source directory under {extract_root}")
        src_dir = src_dir_candidates[0]

        fpm_user, fpm_group = self.detect_fpm_user()
        attempts = []
        full_flags = PHP_CONFIGURE_FLAGS_BASE + PHP_CONFIGURE_FLAGS_OPTIONAL
        attempts.append(("full", full_flags))
        if self.config["php"].get("allow_configure_fallback", True):
            reduced = PHP_CONFIGURE_FLAGS_BASE + ["--enable-zip", "--with-bz2"]
            attempts.append(("reduced_without_gd_intl_xsl", reduced))
            base_only = PHP_CONFIGURE_FLAGS_BASE
            attempts.append(("base_only", base_only))

        last_error = None
        for label, flags in attempts:
            formatted = [x.format(prefix=str(self.php_prefix), fpm_user=fpm_user, fpm_group=fpm_group) for x in flags]
            disabled = [x for x in PHP_CONFIGURE_FLAGS_OPTIONAL if x not in flags]
            self.log(f"Running PHP configure attempt: {label}")
            self.run("make clean || true", cwd=src_dir, check=False)
            cmd = "./configure " + " ".join(shq(x) for x in formatted)
            proc = self.run(cmd, cwd=src_dir, check=False, timeout=1800)
            if proc.returncode == 0:
                self.disabled_php_flags = disabled
                self.log(f"PHP configure succeeded with attempt: {label}")
                self.run(f"make -j$(nproc)", cwd=src_dir, timeout=7200)
                self.run("make install", cwd=src_dir, timeout=3600)
                self.write_file(self.report_dir / "php_configure_flags.txt", "\n".join(formatted) + "\n")
                if disabled:
                    self.warn("Some optional PHP configure flags were disabled after retry: " + ", ".join(disabled))
                break
            last_error = proc.stderr[-4000:] if proc.stderr else proc.stdout[-4000:]
            self.warn(f"PHP configure attempt failed: {label}")
            self.try_autofix_configure_error(last_error)
        else:
            raise DeployError("PHP configure failed after all attempts. Last error:\n" + str(last_error))

        if not self.php_installed_with_correct_version():
            raise DeployError(f"PHP installation did not produce expected PHP {PHP_VERSION} at {self.php_prefix}")
        self.ensure_php_symlink()
        self.configure_php_fpm()

    def try_autofix_configure_error(self, error_text: str) -> None:
        if not error_text:
            return
        mapping = [
            (r"xml2-config|libxml2", ["libxml2-devel"]),
            (r"OpenSSL|openssl", ["openssl-devel"]),
            (r"cURL|curl", ["curl-devel"]),
            (r"zlib", ["zlib-devel"]),
            (r"jpeg|jpeglib", ["libjpeg-devel"]),
            (r"png", ["libpng-devel"]),
            (r"freetype", ["freetype-devel"]),
            (r"ICU|icu", ["libicu-devel"]),
            (r"xslt|xsl", ["libxslt-devel"]),
            (r"bzip2|bz2", ["bzip2-devel"]),
            (r"readline", ["readline-devel"]),
        ]
        to_install: List[str] = []
        for pattern, pkgs in mapping:
            if re.search(pattern, error_text, re.IGNORECASE):
                to_install.extend(pkgs)
        if to_install:
            pkgs = sorted(set(to_install))
            self.warn("Detected missing dependencies from configure error; trying to install: " + ", ".join(pkgs))
            pm = self.package_manager()
            self.run(f"{pm} install -y " + " ".join(pkgs), check=False, timeout=900)
            self.try_offline_rpms()

    def ensure_php_symlink(self) -> None:
        if not self.config["php"].get("create_symlink", True):
            return
        if self.php_symlink.exists() or self.php_symlink.is_symlink():
            if self.php_symlink.is_symlink() and os.readlink(self.php_symlink) == str(self.php_prefix):
                return
            self.backup_path(self.php_symlink)
        self.log(f"Creating PHP symlink {self.php_symlink} -> {self.php_prefix}")
        if not self.dry_run:
            os.symlink(str(self.php_prefix), str(self.php_symlink))
        self.created_files.append(str(self.php_symlink))

    def configure_php_fpm(self) -> None:
        self.log("Configuring php-fpm.")
        fpm_user, fpm_group = self.detect_fpm_user()
        etc_dir = self.php_prefix / "etc"
        confd_dir = etc_dir / "conf.d"
        fpm_pool_dir = etc_dir / "php-fpm.d"
        var_log_dir = self.php_prefix / "var" / "log"
        for d in [etc_dir, confd_dir, fpm_pool_dir, var_log_dir]:
            d.mkdir(parents=True, exist_ok=True)

        src_ini = None
        # Search the latest extracted source for php.ini-production.
        candidates = sorted(self.work_dir.glob(f"php-src-*/php-{PHP_VERSION}*/php.ini-production"), reverse=True)
        if candidates:
            src_ini = candidates[0]
        php_ini = etc_dir / "php.ini"
        if not php_ini.exists():
            if src_ini and src_ini.exists():
                shutil.copy2(str(src_ini), str(php_ini))
            else:
                php_ini.write_text("date.timezone = Asia/Shanghai\n", encoding="utf-8")
            self.created_files.append(str(php_ini))

        fpm_conf = etc_dir / "php-fpm.conf"
        fpm_conf_content = f"""[global]
pid = /run/php-fpm-{PHP_VERSION}.pid
error_log = {self.log_dir}/php-fpm-error.log
include={fpm_pool_dir}/*.conf
"""
        self.write_file(fpm_conf, fpm_conf_content)

        www_conf = fpm_pool_dir / "www.conf"
        www_conf_content = f"""[www]
user = {fpm_user}
group = {fpm_group}
listen = {self.config['php'].get('fpm_listen', DEFAULT_FPM_LISTEN)}
listen.allowed_clients = 127.0.0.1
pm = dynamic
pm.max_children = 20
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 5
catch_workers_output = yes
php_admin_value[error_log] = {self.log_dir}/php-app-php-error.log
php_admin_flag[log_errors] = on
"""
        self.write_file(www_conf, www_conf_content)

        service_path = Path("/etc/systemd/system") / self.service_name
        service_content = f"""[Unit]
Description=PHP {PHP_VERSION} FastCGI Process Manager for ARM migration
After=network.target

[Service]
Type=simple
PIDFile=/run/php-fpm-{PHP_VERSION}.pid
ExecStart={self.php_prefix}/sbin/php-fpm --nodaemonize --fpm-config {fpm_conf}
ExecReload=/bin/kill -USR2 $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
"""
        self.write_file(service_path, service_content)
        self.write_helper_scripts()
        self.run("systemctl daemon-reload", check=False)
        proc = self.run(f"{shq(self.php_prefix / 'sbin' / 'php-fpm')} -t --fpm-config {shq(fpm_conf)}", check=False)
        if proc.returncode != 0:
            raise DeployError("php-fpm configuration test failed.")

    def write_helper_scripts(self) -> None:
        start = self.script_dir / "start_php_stack.sh"
        stop = self.script_dir / "stop_php_stack.sh"
        status = self.script_dir / "status_php_stack.sh"
        verify = self.script_dir / "verify_php_stack.sh"
        self.write_file(start, f"""#!/usr/bin/env bash
set -e
systemctl restart {self.service_name}
systemctl restart nginx
""")
        self.write_file(stop, f"""#!/usr/bin/env bash
set -e
systemctl stop nginx || true
systemctl stop {self.service_name} || true
""")
        self.write_file(status, f"""#!/usr/bin/env bash
systemctl status {self.service_name} --no-pager || true
systemctl status nginx --no-pager || true
""")
        self.write_file(verify, f"""#!/usr/bin/env bash
set -e
{self.php_prefix}/bin/php -v
{self.php_prefix}/bin/php -m
{self.php_prefix}/sbin/php-fpm -t --fpm-config {self.php_prefix}/etc/php-fpm.conf
nginx -t
curl -I http://127.0.0.1:{self.final_nginx_port or 80}/ || true
""")
        for p in [start, stop, status, verify]:
            if not self.dry_run:
                p.chmod(0o755)

    def install_nginx(self) -> None:
        self.log("Installing nginx with yum/dnf first, then offline RPMs if needed.")
        if shutil.which("nginx"):
            self.log("nginx command already exists; skipping package installation.")
            return
        pm = self.package_manager()
        proc = self.run(f"{pm} install -y nginx", check=False, timeout=1200)
        if proc.returncode != 0:
            self.warn("nginx online installation failed. Trying offline RPM installation.")
            nginx_rpms = sorted(str(p) for p in self.packages_dir.glob("*nginx*.rpm"))
            all_rpms = sorted(str(p) for p in self.packages_dir.glob("*.rpm"))
            rpms = nginx_rpms or all_rpms
            if rpms:
                self.run(f"{pm} localinstall -y " + " ".join(shq(x) for x in rpms), check=False, timeout=1200)
        if not shutil.which("nginx"):
            raise DeployError(f"nginx installation failed. Please upload nginx aarch64 RPMs and dependencies to {self.packages_dir}.")

    def find_app_package(self) -> Path:
        explicit = self.config["app"].get("package", "")
        if explicit and explicit.lower() != "auto":
            p = Path(explicit)
            if not p.exists():
                raise DeployError(f"Application package not found: {p}")
            return p
        candidates: List[Path] = []
        patterns = ["*.tar.gz", "*.tgz", "*.zip"]
        for pattern in patterns:
            for p in self.packages_dir.glob(pattern):
                name = p.name.lower()
                if name.startswith(f"php-{PHP_VERSION}"):
                    continue
                if "php-7.0.33" in name:
                    continue
                candidates.append(p)
        if not candidates:
            raise DeployError(f"Application package not found. Put app.tar.gz or app.zip under {self.packages_dir}, or set app.package in config.")
        # Prefer names containing app/demo/project.
        candidates.sort(key=lambda p: (0 if re.search(r"app|demo|project|php-app", p.name, re.I) else 1, p.name))
        self.log(f"Auto-selected application package: {candidates[0]}")
        return candidates[0]

    def deploy_app(self) -> None:
        app_pkg = self.find_app_package()
        self.log(f"Deploying application package: {app_pkg}")
        self.backup_path(self.app_deploy_dir)
        self.app_deploy_dir.mkdir(parents=True, exist_ok=True)
        tmp = self.work_dir / f"app-extract-{self.timestamp}"
        if tmp.exists():
            shutil.rmtree(str(tmp))
        tmp.mkdir(parents=True)
        if app_pkg.suffix.lower() == ".zip":
            with zipfile.ZipFile(app_pkg) as zf:
                safe_extract_zip(zf, tmp)
        elif app_pkg.name.endswith(".tar.gz") or app_pkg.name.endswith(".tgz"):
            with tarfile.open(app_pkg, "r:gz") as tar:
                safe_extract_tar(tar, tmp)
        else:
            raise DeployError(f"Unsupported application package format: {app_pkg}")

        entries = [p for p in tmp.iterdir() if p.name not in ("__MACOSX",)]
        source_root = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
        move_contents(source_root, self.app_deploy_dir)
        self.log(f"Application deployed to {self.app_deploy_dir}")
        self.final_web_root = str(self.detect_web_root())
        self.scan_application_config()

    def detect_web_root(self) -> Path:
        configured = self.config["app"].get("web_root", "auto")
        if configured and configured.lower() != "auto":
            p = Path(configured)
            if not p.is_absolute():
                p = self.app_deploy_dir / configured
            if p.exists():
                return p
            self.warn(f"Configured web_root does not exist: {p}; falling back to auto detection.")
        for name in ["public", "web", "www", "htdocs"]:
            p = self.app_deploy_dir / name
            if p.exists() and p.is_dir():
                return p
        return self.app_deploy_dir

    def candidate_web_roots(self) -> List[Path]:
        roots = [self.detect_web_root()]
        for name in ["public", "web", "www", "htdocs", "."]:
            p = self.app_deploy_dir if name == "." else self.app_deploy_dir / name
            if p.exists() and p.is_dir() and p not in roots:
                roots.append(p)
        return roots

    def pick_nginx_port_candidates(self) -> List[int]:
        configured = self.config["nginx"].get("listen_port", 80)
        ports = [int(configured)] + [p for p in DEFAULT_PORT_CANDIDATES if p != int(configured)]
        return ports

    def port_is_in_use(self, port: int) -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            return s.connect_ex(("127.0.0.1", port)) == 0

    def write_nginx_config(self, port: int, web_root: Path) -> None:
        conf_dir = Path("/etc/nginx/conf.d")
        conf_dir.mkdir(parents=True, exist_ok=True)
        conf_path = conf_dir / "php_app.conf"
        if conf_path.exists():
            backup = conf_path.with_name(f"php_app.conf.bak_{self.timestamp}")
            self.log(f"Backing up existing nginx app config to {backup}")
            if not self.dry_run:
                shutil.copy2(str(conf_path), str(backup))
            self.backups.append(str(backup))
        fpm_listen = self.config["php"].get("fpm_listen", DEFAULT_FPM_LISTEN)
        content = f"""server {{
    listen {port};
    server_name _;

    root {web_root};
    index index.php index.html index.htm;

    access_log {self.log_dir}/nginx_php_app_access.log;
    error_log  {self.log_dir}/nginx_php_app_error.log;

    location / {{
        try_files $uri $uri/ /index.php?$query_string;
    }}

    location ~ \\.php$ {{
        include fastcgi_params;
        fastcgi_pass {fpm_listen};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
    }}
}}
"""
        self.write_file(conf_path, content)

    def configure_and_start_services(self) -> None:
        self.log("Configuring nginx and starting php-fpm/nginx with automatic access debugging.")
        self.install_nginx()
        self.run("systemctl daemon-reload", check=False)
        self.run(f"systemctl enable {self.service_name}", check=False)
        self.run(f"systemctl restart {self.service_name}", check=False)
        time.sleep(1)

        tried: List[str] = []
        last_status = None
        for port in self.pick_nginx_port_candidates():
            if self.port_is_in_use(port):
                self.warn(f"Port {port} is already in use before nginx app config. Trying next port.")
                continue
            for web_root in self.candidate_web_roots():
                tried.append(f"port={port}, web_root={web_root}")
                self.write_nginx_config(port, web_root)
                test = self.run("nginx -t", check=False)
                if test.returncode != 0:
                    self.warn(f"nginx -t failed for port={port}, web_root={web_root}")
                    continue
                self.run("systemctl enable nginx", check=False)
                self.run("systemctl restart nginx", check=False)
                self.run(f"systemctl restart {self.service_name}", check=False)
                time.sleep(2)
                status = self.http_status(port)
                last_status = status
                self.log(f"HTTP verification for port={port}, web_root={web_root}: status={status}")
                if status == "200":
                    self.final_nginx_port = port
                    self.final_web_root = str(web_root)
                    self.final_http_status = status
                    self.write_helper_scripts()
                    return
                # 302 is commonly a login redirect. It is not the primary success criterion,
                # but useful enough to record and stop only if config says so.
                if status in ("301", "302") and self.config["verify"].get("accept_redirect", False):
                    self.final_nginx_port = port
                    self.final_web_root = str(web_root)
                    self.final_http_status = status
                    self.write_helper_scripts()
                    self.warn(f"HTTP status is {status}; accepted by configuration but not strict HTTP 200.")
                    return
                if status == "502":
                    self.collect_logs(prefix="debug_502")
                    self.run(f"systemctl restart {self.service_name}", check=False)
        self.final_http_status = last_status
        raise DeployError("Failed to make nginx return HTTP 200 for the PHP application. Tried: " + "; ".join(tried))

    def http_status(self, port: int) -> str:
        if shutil.which("curl"):
            proc = self.run(f"curl -L -s -o /tmp/php_migration_http_body.txt -w '%{{http_code}}' --max-time 10 http://127.0.0.1:{port}/", check=False)
            return (proc.stdout or "").strip()[-3:] or "000"
        # Fallback to Python socket minimal HTTP request.
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
                s.sendall(b"GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
                data = s.recv(1024).decode("latin1", errors="ignore")
            m = re.search(r"HTTP/\S+\s+(\d{3})", data)
            return m.group(1) if m else "000"
        except Exception:
            return "000"

    def verify_stack(self) -> None:
        self.log("Running final verification checks.")
        commands = [
            f"{shq(self.php_prefix / 'bin' / 'php')} -v",
            f"{shq(self.php_prefix / 'bin' / 'php')} -m",
            f"{shq(self.php_prefix / 'sbin' / 'php-fpm')} -t --fpm-config {shq(self.php_prefix / 'etc' / 'php-fpm.conf')}",
            f"systemctl status {self.service_name} --no-pager",
            "nginx -t",
            "systemctl status nginx --no-pager",
        ]
        for cmd in commands:
            proc = self.run(cmd, check=False)
            if proc.returncode != 0:
                self.warn(f"Verification command failed: {cmd}")
        if self.final_nginx_port:
            self.final_http_status = self.http_status(self.final_nginx_port)
            if self.final_http_status != "200":
                self.warn(f"Final HTTP status is {self.final_http_status}, expected 200.")

    def scan_application_config(self) -> None:
        self.log("Scanning application package for IP/domain/database/Redis/path configuration hints.")
        findings: List[Dict[str, Any]] = []
        ipv4_re = re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b")
        domain_re = re.compile(r"\b(?:[a-zA-Z0-9-]+\.)+(?:com|cn|net|org|io|local|internal|corp|dev|test)\b")
        abs_path_re = re.compile(r"(?<![A-Za-z0-9_])/(?:opt|data|home|var|usr|tmp|app|www)/[A-Za-z0-9_./-]+")
        keywords = [
            "DB_HOST", "DB_PORT", "DB_DATABASE", "DB_USERNAME", "DB_PASSWORD", "DATABASE_URL",
            "mysql", "mysqli", "pdo_mysql", "redis", "REDIS_HOST", "REDIS_PORT", "CACHE_DRIVER",
            "host", "hostname", "server", "upload", "log_path", "runtime", "storage",
        ]
        for path in self.app_deploy_dir.rglob("*"):
            if not path.is_file():
                continue
            if path.stat().st_size > int(self.config["scan"].get("max_file_size", 1024 * 1024)):
                continue
            if not self.is_text_candidate(path):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            rel = str(path.relative_to(self.app_deploy_dir))
            file_hits: Dict[str, Any] = {"file": str(path), "relative_file": rel}
            ips = sorted(set(ipv4_re.findall(text)))
            domains = sorted(set(domain_re.findall(text)))
            paths = sorted(set(abs_path_re.findall(text)))[:50]
            lines = []
            for i, line in enumerate(text.splitlines(), 1):
                low = line.lower()
                if any(k.lower() in low for k in keywords):
                    if len(line) > 300:
                        line = line[:300] + "..."
                    lines.append({"line": i, "text": mask_secret(line.strip())})
                if len(lines) >= 80:
                    break
            if ips:
                file_hits["ip_addresses"] = ips[:50]
            if domains:
                file_hits["domains"] = domains[:50]
            if paths:
                file_hits["absolute_paths"] = paths
            if lines:
                file_hits["keyword_lines"] = lines
            if len(file_hits) > 2:
                file_hits["suggestion"] = self.suggest_for_finding(file_hits)
                findings.append(file_hits)
        self.scan_findings = findings
        scan_json = self.report_dir / f"application_config_scan_{self.timestamp}.json"
        self.write_file(scan_json, json.dumps(findings, indent=2, ensure_ascii=False))

        composer_json = self.app_deploy_dir / "composer.json"
        vendor_dir = self.app_deploy_dir / "vendor"
        if composer_json.exists() and not vendor_dir.exists():
            self.warn("composer.json exists but vendor/ does not exist. Composer install is not executed in offline mode; application dependencies may be missing.")

    def is_text_candidate(self, path: Path) -> bool:
        if path.name in CONFIG_FILE_HINTS:
            return True
        if path.suffix.lower() in TEXT_EXTENSIONS:
            return True
        return any(fnmatch.fnmatch(str(path).lower(), f"*{hint.lower()}") for hint in CONFIG_FILE_HINTS)

    def suggest_for_finding(self, finding: Dict[str, Any]) -> str:
        parts = []
        if finding.get("ip_addresses"):
            parts.append("确认硬编码 IP 是否仍能从 ARM 目标机访问；如数据库仍在源服务器，需放通网络、防火墙和数据库白名单。")
        if finding.get("domains"):
            parts.append("确认域名解析在 XC/openEuler 环境中是否可用，必要时配置 DNS 或 /etc/hosts。")
        if finding.get("keyword_lines"):
            parts.append("检查数据库、Redis、缓存、日志、上传目录等配置是否需要按目标环境调整。")
        if finding.get("absolute_paths"):
            parts.append("确认绝对路径在 ARM 目标机上存在且权限可读写。")
        return "".join(parts) or "请人工确认该配置项是否需要适配目标环境。"

    def collect_logs(self, prefix: str = "final") -> None:
        self.log("Collecting service logs.")
        log_bundle = self.log_dir / f"{prefix}_service_logs_{self.timestamp}.log"
        commands = [
            f"journalctl -u {self.service_name} --no-pager -n 200",
            "journalctl -u nginx --no-pager -n 200",
            "tail -n 200 /var/log/nginx/error.log",
            f"tail -n 200 {self.log_dir}/nginx_php_app_error.log",
            f"tail -n 200 {self.log_dir}/php-fpm-error.log",
            f"tail -n 200 {self.log_dir}/php-app-php-error.log",
        ]
        with log_bundle.open("w", encoding="utf-8", errors="ignore") as out:
            for cmd in commands:
                out.write(f"\n\n===== {cmd} =====\n")
                proc = self.run(cmd, check=False)
                out.write(proc.stdout or "")
                out.write(proc.stderr or "")
        self.created_files.append(str(log_bundle))

    def pack_runtime(self) -> None:
        if not self.config["runtime_pack"].get("enabled", False):
            return
        self.log("Packing PHP ARM runtime.")
        if not self.php_prefix.exists():
            self.warn("PHP prefix does not exist; runtime package skipped.")
            return
        target = self.runtime_dir / f"php-{PHP_VERSION}-openeuler22.03-aarch64.tar.gz"
        meta = self.runtime_dir / f"php-{PHP_VERSION}-runtime-readme.txt"
        meta.write_text(textwrap.dedent(f"""
            PHP ARM runtime package
            =======================
            PHP version: {PHP_VERSION}
            Source install prefix: {self.php_prefix}
            Suggested extract path: {self.php_prefix}
            System target: openEuler 22.03 aarch64
            php-fpm service: /etc/systemd/system/{self.service_name}
            PHP extension list: see report {self.report_md}
            Configure flags: see {self.report_dir}/php_configure_flags.txt

            Note:
            - This package contains compiled PHP runtime files only.
            - It does not contain nginx, application code, database data, or system RPM dependencies.
            - Use the same or compatible openEuler/glibc environment.
        """).strip() + "\n", encoding="utf-8")
        cmd = f"tar -czf {shq(target)} -C / {shq(str(self.php_prefix).lstrip('/'))} -C {shq(self.runtime_dir)} {shq(meta.name)}"
        self.run(cmd, check=False, timeout=1800)
        if target.exists():
            self.created_files.append(str(target))
            self.log(f"Runtime package generated: {target}")

    def write_file(self, path: Path, content: str) -> None:
        self.log(f"Writing file: {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
        if self.dry_run:
            return
        path.write_text(content, encoding="utf-8")
        self.created_files.append(str(path))

    def write_report(self) -> None:
        self.diff_rpm()
        php_v = self.run(f"{shq(self.php_prefix / 'bin' / 'php')} -v", check=False).stdout.strip() if (self.php_prefix / "bin" / "php").exists() else "N/A"
        php_m = self.run(f"{shq(self.php_prefix / 'bin' / 'php')} -m", check=False).stdout.strip() if (self.php_prefix / "bin" / "php").exists() else "N/A"
        data = {
            "started_at": self.started_at.isoformat(),
            "finished_at": _dt.datetime.now().isoformat(),
            "system_info": self.system_info,
            "php_version_output": php_v,
            "php_modules_output": php_m,
            "php_prefix": str(self.php_prefix),
            "php_symlink": str(self.php_symlink),
            "php_service": self.service_name,
            "app_deploy_dir": str(self.app_deploy_dir),
            "web_root": self.final_web_root,
            "nginx_port": self.final_nginx_port,
            "http_status": self.final_http_status,
            "installed_packages": self.installed_packages,
            "created_files": sorted(set(self.created_files)),
            "backups": self.backups,
            "disabled_php_flags": self.disabled_php_flags,
            "warnings": self.warnings,
            "failures": self.failures,
            "download_attempts": self.download_attempts,
            "scan_findings": self.scan_findings,
            "log_file": str(self.log_file),
        }
        self.report_json.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

        md = []
        md.append(f"# PHP 应用 x86 到 ARM 部署报告\n")
        md.append(f"生成时间：{_dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        md.append("## 1. 部署结论\n")
        if self.failures:
            md.append("- 状态：失败或部分失败\n")
        elif self.final_http_status == "200":
            md.append("- 状态：成功，HTTP 访问返回 200\n")
        else:
            md.append(f"- 状态：完成但需要确认，HTTP 状态：{self.final_http_status}\n")
        md.append(f"- PHP 安装路径：`{self.php_prefix}`\n")
        md.append(f"- PHP 兼容链接：`{self.php_symlink}`\n")
        md.append(f"- 应用部署路径：`{self.app_deploy_dir}`\n")
        md.append(f"- Web 根目录：`{self.final_web_root}`\n")
        md.append(f"- nginx 访问地址：`http://127.0.0.1:{self.final_nginx_port or 'N/A'}/`\n")
        md.append(f"- php-fpm 监听：`{self.config['php'].get('fpm_listen', DEFAULT_FPM_LISTEN)}`\n")
        md.append(f"- php-fpm 服务：`{self.service_name}`\n")
        md.append("\n## 2. 系统信息\n")
        for k, v in self.system_info.items():
            md.append(f"- {k}: `{v}`\n")
        md.append("\n## 3. PHP 信息\n")
        md.append("```\n" + php_v + "\n```\n")
        md.append("### PHP 扩展列表\n")
        md.append("```\n" + php_m + "\n```\n")
        if self.disabled_php_flags:
            md.append("### 编译降级说明\n")
            md.append("以下可选编译参数在自动重试中被关闭，需要按需补齐依赖后重新编译：\n")
            for flag in self.disabled_php_flags:
                md.append(f"- `{flag}`\n")
        md.append("\n## 4. 新增安装的软件包\n")
        if self.installed_packages:
            for p in self.installed_packages:
                md.append(f"- {p}\n")
        else:
            md.append("- 未检测到新增 RPM 包，或 rpm 快照不可用。\n")
        md.append("\n## 5. 创建或修改的文件\n")
        for p in sorted(set(self.created_files)):
            md.append(f"- `{p}`\n")
        md.append("\n## 6. 自动备份\n")
        if self.backups:
            for p in self.backups:
                md.append(f"- `{p}`\n")
        else:
            md.append("- 无。\n")
        md.append("\n## 7. 应用配置扫描结果\n")
        if self.scan_findings:
            for item in self.scan_findings[:100]:
                md.append(f"### `{item.get('relative_file', item.get('file'))}`\n")
                if item.get("ip_addresses"):
                    md.append("- 疑似 IP：" + ", ".join(f"`{x}`" for x in item["ip_addresses"][:20]) + "\n")
                if item.get("domains"):
                    md.append("- 疑似域名：" + ", ".join(f"`{x}`" for x in item["domains"][:20]) + "\n")
                if item.get("absolute_paths"):
                    md.append("- 疑似绝对路径：" + ", ".join(f"`{x}`" for x in item["absolute_paths"][:20]) + "\n")
                if item.get("keyword_lines"):
                    md.append("- 疑似配置行：\n")
                    for line in item["keyword_lines"][:10]:
                        md.append(f"  - L{line['line']}: `{line['text']}`\n")
                md.append(f"- 建议：{item.get('suggestion', '请人工确认。')}\n")
        else:
            md.append("- 未扫描到明显的 IP、域名、数据库或 Redis 配置。\n")
        md.append("\n## 8. 警告\n")
        if self.warnings:
            for w in self.warnings:
                md.append(f"- {w}\n")
        else:
            md.append("- 无。\n")
        md.append("\n## 9. 失败项\n")
        if self.failures:
            for f in self.failures:
                md.append(f"- {f}\n")
        else:
            md.append("- 无。\n")
        md.append("\n## 10. 日志与结果文件\n")
        md.append(f"- 执行日志：`{self.log_file}`\n")
        md.append(f"- JSON 报告：`{self.report_json}`\n")
        md.append(f"- RPM 快照 before：`{self.rpm_before}`\n")
        md.append(f"- RPM 快照 after：`{self.rpm_after}`\n")
        md.append(f"- 新增包清单：`{self.installed_pkg_file}`\n")
        md.append("\n## 11. 回退说明\n")
        md.append("本工具不会自动卸载已安装内容，也不会自动删除已有系统组件。请根据新增包清单、创建文件清单和备份路径人工确认后再执行回退。\n")
        self.report_md.write_text("".join(md), encoding="utf-8")
        self.log(f"Report generated: {self.report_md}")
        self.log(f"JSON report generated: {self.report_json}")

    def run_all(self) -> int:
        exit_code = 0
        try:
            self.prepare_dirs()
            self.precheck()
            self.install_dependencies()
            self.build_php()
            self.deploy_app()
            self.configure_and_start_services()
            self.verify_stack()
            self.pack_runtime()
        except Exception as e:
            exit_code = 1
            self.fail(str(e))
            try:
                self.collect_logs(prefix="failure")
            except Exception as log_err:
                self.warn(f"Failed to collect logs: {log_err}")
        finally:
            try:
                self.collect_logs(prefix="final")
            except Exception as log_err:
                self.warn(f"Failed to collect final logs: {log_err}")
            self.write_report()
        return exit_code

    def run_verify_only(self) -> int:
        self.prepare_dirs()
        self.precheck()
        try:
            self.verify_stack()
            self.collect_logs(prefix="verify")
        except Exception as e:
            self.fail(str(e))
            return 1
        finally:
            self.write_report()
        return 0

    def run_scan_only(self) -> int:
        self.prepare_dirs()
        if not self.app_deploy_dir.exists():
            self.fail(f"Application deploy dir does not exist: {self.app_deploy_dir}")
            self.write_report()
            return 1
        self.scan_application_config()
        self.write_report()
        return 0


def shq(value: Any) -> str:
    s = str(value)
    return "'" + s.replace("'", "'\\''") + "'"


def user_exists(name: str) -> bool:
    try:
        import pwd
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


def mask_secret(line: str) -> str:
    # Mask common secrets while keeping configuration context visible.
    patterns = [
        (r"(?i)(password\s*[=:]\s*)[^\s'\"]+", r"\1******"),
        (r"(?i)(passwd\s*[=:]\s*)[^\s'\"]+", r"\1******"),
        (r"(?i)(secret\s*[=:]\s*)[^\s'\"]+", r"\1******"),
        (r"(?i)(token\s*[=:]\s*)[^\s'\"]+", r"\1******"),
        (r"(?i)(key\s*[=:]\s*)[^\s'\"]+", r"\1******"),
    ]
    out = line
    for pat, repl in patterns:
        out = re.sub(pat, repl, out)
    return out


def safe_extract_tar(tar: tarfile.TarFile, path: Path) -> None:
    base = path.resolve()
    for member in tar.getmembers():
        dest = (path / member.name).resolve()
        if not str(dest).startswith(str(base)):
            raise DeployError(f"Unsafe path in tar archive: {member.name}")
    tar.extractall(path)


def safe_extract_zip(zf: zipfile.ZipFile, path: Path) -> None:
    base = path.resolve()
    for member in zf.infolist():
        dest = (path / member.filename).resolve()
        if not str(dest).startswith(str(base)):
            raise DeployError(f"Unsafe path in zip archive: {member.filename}")
    zf.extractall(path)


def move_contents(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if target.exists():
            # The deploy dir should normally be empty after backup, but keep this safe.
            backup = dst / f"{item.name}.bak_{int(time.time())}"
            shutil.move(str(target), str(backup))
        shutil.move(str(item), str(target))


def default_config() -> Dict[str, Any]:
    return {
        "paths": {
            "base_dir": str(DEFAULT_BASE_DIR),
            "packages_dir": str(DEFAULT_PACKAGES_DIR),
            "work_dir": str(DEFAULT_WORK_DIR),
            "log_dir": str(DEFAULT_LOG_DIR),
            "report_dir": str(DEFAULT_REPORT_DIR),
            "script_dir": str(DEFAULT_SCRIPT_DIR),
            "runtime_dir": str(DEFAULT_RUNTIME_DIR),
        },
        "php": {
            "version": PHP_VERSION,
            "source_package": str(DEFAULT_PACKAGES_DIR / f"php-{PHP_VERSION}.tar.gz"),
            "install_prefix": str(DEFAULT_PHP_PREFIX),
            "create_symlink": True,
            "symlink": str(DEFAULT_PHP_SYMLINK),
            "fpm_listen": DEFAULT_FPM_LISTEN,
            "service_name": f"php-fpm-{PHP_VERSION}.service",
            "allow_configure_fallback": True,
        },
        "nginx": {
            "listen_port": 80,
            "port_candidates": DEFAULT_PORT_CANDIDATES,
            "config_path": "/etc/nginx/conf.d/php_app.conf",
        },
        "app": {
            "package": "auto",
            "deploy_dir": str(DEFAULT_APP_DEPLOY_DIR),
            "web_root": "auto",
        },
        "scan": {
            "enabled": True,
            "max_file_size": 1048576,
        },
        "verify": {
            "accept_redirect": False,
        },
        "runtime_pack": {
            "enabled": False,
        },
    }


def merge_dict(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge_dict(out[k], v)
        else:
            out[k] = v
    return out


def load_config(path: Optional[str]) -> Dict[str, Any]:
    cfg = default_config()
    if not path:
        return cfg
    p = Path(path)
    if not p.exists():
        raise DeployError(f"Config file does not exist: {p}")
    text = p.read_text(encoding="utf-8")
    if p.suffix.lower() == ".json":
        user_cfg = json.loads(text)
    else:
        user_cfg = parse_simple_yaml(text)
    return merge_dict(cfg, user_cfg)


def parse_scalar(value: str) -> Any:
    v = value.strip()
    if v in ("", "null", "None", "~"):
        return "" if v == "" else None
    if v.lower() == "true":
        return True
    if v.lower() == "false":
        return False
    if re.fullmatch(r"-?\d+", v):
        try:
            return int(v)
        except Exception:
            pass
    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
        return v[1:-1]
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        if not inner:
            return []
        return [parse_scalar(x.strip()) for x in inner.split(",")]
    return v


def parse_simple_yaml(text: str) -> Dict[str, Any]:
    """A small YAML subset parser to avoid requiring PyYAML on target machines.

    Supported:
      key: value
      parent:
        child: value
    Comments and blank lines are ignored. This is enough for the provided config.yaml.
    """
    root: Dict[str, Any] = {}
    stack: List[Tuple[int, Dict[str, Any]]] = [(-1, root)]
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        key = key.strip().strip('"\'')
        val = val.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if val == "":
            new: Dict[str, Any] = {}
            parent[key] = new
            stack.append((indent, new))
        else:
            parent[key] = parse_scalar(val)
    return root


def main() -> int:
    parser = argparse.ArgumentParser(description="Deploy PHP 7.0.33 application stack on openEuler ARM.")
    parser.add_argument("--config", default="/opt/migration/config.yaml", help="Path to config.yaml or config.json.")
    parser.add_argument("--mode", choices=["all", "verify", "scan"], default="all", help="Execution mode.")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without changing the system.")
    parser.add_argument("--php-source", help="Override PHP source package path.")
    parser.add_argument("--app-package", help="Override application package path.")
    parser.add_argument("--runtime-pack", action="store_true", help="Enable PHP runtime packaging.")
    args = parser.parse_args()

    cfg = load_config(args.config if Path(args.config).exists() else None)
    if args.php_source:
        cfg["php"]["source_package"] = args.php_source
    if args.app_package:
        cfg["app"]["package"] = args.app_package
    if args.runtime_pack:
        cfg["runtime_pack"]["enabled"] = True

    exe = Executor(cfg, dry_run=args.dry_run)
    if args.mode == "verify":
        return exe.run_verify_only()
    if args.mode == "scan":
        return exe.run_scan_only()
    return exe.run_all()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(130)

#!/usr/bin/env python3
"""Package discovery and download helper for ai-system-migration.

The resolver is intentionally deterministic:
1. search user-provided local package directories first;
2. optionally crawl configured HTTP directory indexes such as Huawei Kunpeng archive;
3. optionally try configured official direct URLs.

It does not silently substitute products. If the requested package cannot be
resolved, callers must stop the current phase or ask for user input.
"""
from __future__ import annotations

import hashlib
import os
import re
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

ARCHIVE_URL = "https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/"

PACKAGE_RULES: Dict[str, Dict[str, Any]] = {
    "tongweb": {
        "patterns": [r"tongweb", r"东方通"],
        "extensions": [".tar.gz", ".tgz", ".zip", ".bin", ".sh", ".jar"],
        "arch_patterns": [r"arm", r"aarch64", r"kunpeng", r"linux"],
    },
    "tongweb-license": {
        "patterns": [r"license", r"tongweb"],
        "extensions": [".dat", ".lic", ".license"],
        "arch_patterns": [],
    },
    "dm": {
        "patterns": [r"dm8", r"dm_?8", r"dmdbms", r"DMInstall", r"达梦"],
        "extensions": [".iso", ".bin", ".zip", ".tar.gz", ".tgz"],
        "arch_patterns": [r"arm", r"aarch64", r"kunpeng", r"linux"],
    },
    "openjdk": {
        "patterns": [r"openjdk", r"bisheng", r"毕昇", r"jdk"],
        "extensions": [".tar.gz", ".tgz", ".zip", ".rpm"],
        "arch_patterns": [r"arm", r"aarch64", r"linux"],
    },
    "redis": {
        "patterns": [r"redis"],
        "extensions": [".tar.gz", ".tgz", ".zip", ".rpm"],
        "arch_patterns": [r"arm", r"aarch64", r"linux", r"src"],
    },
    "nginx": {
        "patterns": [r"nginx"],
        "extensions": [".tar.gz", ".tgz", ".zip", ".rpm"],
        "arch_patterns": [r"arm", r"aarch64", r"linux", r"src"],
    },
    "resin": {
        "patterns": [r"resin"],
        "extensions": [".tar.gz", ".tgz", ".zip"],
        "arch_patterns": [r"arm", r"aarch64", r"linux"],
    },
}


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        if tag.lower() != "a":
            return
        for k, v in attrs:
            if k.lower() == "href" and v:
                self.links.append(v)


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _lower_name(path_or_url: str) -> str:
    return urllib.parse.unquote(Path(urllib.parse.urlparse(path_or_url).path).name).lower()


def _has_ext(name: str, exts: Iterable[str]) -> bool:
    n = name.lower()
    return any(n.endswith(e.lower()) for e in exts)


def _score_candidate(name: str, rule: Dict[str, Any]) -> int:
    n = name.lower()
    score = 0
    for pat in rule.get("patterns", []):
        if re.search(pat, n, flags=re.I):
            score += 20
    for pat in rule.get("arch_patterns", []):
        if re.search(pat, n, flags=re.I):
            score += 4
    if "arm" in n or "aarch64" in n:
        score += 8
    if "x86" in n or "x64" in n or "amd64" in n:
        score -= 50
    if "license" in n or n.endswith(".lic") or n.endswith(".dat"):
        score += 3
    return score


def _matches_package(path_or_url: str, package_type: str) -> bool:
    rule = PACKAGE_RULES.get(package_type, {})
    name = _lower_name(path_or_url)
    if not _has_ext(name, rule.get("extensions", [])):
        return False
    return _score_candidate(name, rule) >= 20


def local_candidate_dirs(config: Dict[str, Any]) -> List[Path]:
    workspace = Path(config.get("workspace", "/opt/ai-system-migration"))
    dirs: List[str] = []
    middleware = config.get("middleware", {})
    database = config.get("database", {})
    for item in middleware.get("package_sources", []) or []:
        if isinstance(item, dict) and item.get("path"):
            dirs.append(str(item["path"]))
    for key in ["package_dir", "install_package_dir"]:
        if database.get(key):
            dirs.append(str(database[key]))
    dirs.extend([
        str(workspace / "packages"),
        str(workspace / "packages" / "middleware"),
        str(workspace / "packages" / "database"),
        str(workspace / "packages" / "dm"),
        str(workspace / "packages" / "tongweb"),
        "/opt/ai-system-migration/packages",
        "/opt/ai-system-migration/packages/middleware",
        "/opt/ai-system-migration/packages/database",
        "/opt/ai-system-migration/packages/dm",
        "/opt/ai-system-migration/packages/tongweb",
    ])
    unique: List[Path] = []
    seen = set()
    for d in dirs:
        p = Path(os.path.expandvars(d)).expanduser()
        if str(p) not in seen:
            unique.append(p)
            seen.add(str(p))
    return unique


def find_local_packages(package_type: str, config: Dict[str, Any]) -> List[Dict[str, Any]]:
    rule = PACKAGE_RULES.get(package_type)
    if not rule:
        return []
    found: List[Dict[str, Any]] = []
    for base in local_candidate_dirs(config):
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if not p.is_file():
                continue
            name = p.name.lower()
            if not _has_ext(name, rule.get("extensions", [])):
                continue
            score = _score_candidate(name, rule)
            if score >= 20:
                found.append({
                    "source_type": "local",
                    "package_type": package_type,
                    "path": str(p),
                    "file_name": p.name,
                    "size_bytes": p.stat().st_size,
                    "sha256": sha256_file(p),
                    "score": score,
                })
    found.sort(key=lambda x: (x.get("score", 0), x.get("size_bytes", 0)), reverse=True)
    return found


def _http_get_text(url: str, timeout: int = 15) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "ai-system-migration-skill/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="ignore")


def crawl_http_index(base_url: str, package_type: str, max_depth: int = 2, max_pages: int = 80) -> List[Dict[str, Any]]:
    base_url = base_url.rstrip("/") + "/"
    rule = PACKAGE_RULES.get(package_type)
    if not rule:
        return []
    visited = set()
    queue: List[Tuple[str, int]] = [(base_url, 0)]
    candidates: List[Dict[str, Any]] = []
    pages = 0
    while queue and pages < max_pages:
        url, depth = queue.pop(0)
        if url in visited or depth > max_depth:
            continue
        visited.add(url)
        pages += 1
        try:
            html = _http_get_text(url)
        except Exception as exc:
            continue
        parser = LinkParser()
        parser.feed(html)
        for href in parser.links:
            if href.startswith("?") or href.startswith("#") or href.startswith("mailto:"):
                continue
            child = urllib.parse.urljoin(url, href)
            if not child.startswith(base_url):
                continue
            name = _lower_name(child)
            if href.endswith("/"):
                # Prefer branches that look relevant, but keep shallow root traversal.
                if depth + 1 <= max_depth:
                    if depth == 0 or any(re.search(p, name, re.I) for p in rule.get("patterns", [])):
                        queue.append((child, depth + 1))
                continue
            if _matches_package(child, package_type):
                candidates.append({
                    "source_type": "http-index",
                    "package_type": package_type,
                    "url": child,
                    "file_name": Path(urllib.parse.urlparse(child).path).name,
                    "score": _score_candidate(name, rule),
                })
    candidates.sort(key=lambda x: x.get("score", 0), reverse=True)
    return candidates


def configured_remote_sources(config: Dict[str, Any]) -> List[str]:
    urls: List[str] = []
    for item in config.get("middleware", {}).get("package_sources", []) or []:
        if isinstance(item, dict) and item.get("url"):
            urls.append(str(item["url"]))
    database = config.get("database", {})
    for key in ["package_urls", "official_urls"]:
        for url in database.get(key, []) or []:
            urls.append(str(url))
    # Keep Huawei Kunpeng archive as required fallback.
    if ARCHIVE_URL not in urls:
        urls.append(ARCHIVE_URL)
    # Optional official direct candidates. These should be direct package URLs or index pages.
    for url in config.get("package_resolution", {}).get("official_urls", []) or []:
        urls.append(str(url))
    unique: List[str] = []
    seen = set()
    for u in urls:
        if u and u not in seen:
            unique.append(u)
            seen.add(u)
    return unique


def find_remote_packages(package_type: str, config: Dict[str, Any]) -> List[Dict[str, Any]]:
    pr = config.get("package_resolution", {})
    if not pr.get("remote_search_enabled", True):
        return []
    max_depth = int(pr.get("http_index_max_depth", 2))
    max_pages = int(pr.get("http_index_max_pages", 80))
    found: List[Dict[str, Any]] = []
    for url in configured_remote_sources(config):
        # Direct package URL.
        if _matches_package(url, package_type):
            found.append({
                "source_type": "direct-url",
                "package_type": package_type,
                "url": url,
                "file_name": Path(urllib.parse.urlparse(url).path).name,
                "score": _score_candidate(_lower_name(url), PACKAGE_RULES.get(package_type, {})),
            })
            continue
        if url.endswith("/"):
            found.extend(crawl_http_index(url, package_type, max_depth=max_depth, max_pages=max_pages))
    found.sort(key=lambda x: x.get("score", 0), reverse=True)
    return found


def download_candidate(candidate: Dict[str, Any], dest_dir: str | Path) -> Dict[str, Any]:
    if candidate.get("source_type") == "local":
        return candidate
    url = candidate.get("url")
    if not url:
        raise ValueError("candidate has no url")
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    filename = candidate.get("file_name") or Path(urllib.parse.urlparse(url).path).name
    dest = dest_dir / filename
    req = urllib.request.Request(url, headers={"User-Agent": "ai-system-migration-skill/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp, dest.open("wb") as out:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
    result = dict(candidate)
    result.update({
        "source_type": "downloaded",
        "url": url,
        "path": str(dest),
        "size_bytes": dest.stat().st_size,
        "sha256": sha256_file(dest),
        "downloaded_at": int(time.time()),
    })
    return result


def resolve_package(package_type: str, config: Dict[str, Any], download: bool = False) -> Dict[str, Any]:
    """Resolve a package and return a structured result.

    The function never falls back to another product. It returns waiting_input when
    the exact requested package cannot be found.
    """
    local = find_local_packages(package_type, config)
    if local:
        return {"status": "found", "package_type": package_type, "selected": local[0], "candidates": local[:10]}
    remote = find_remote_packages(package_type, config)
    if remote:
        if download or config.get("package_resolution", {}).get("download_enabled", False):
            dest = Path(config.get("workspace", "/opt/ai-system-migration")) / "packages" / package_type
            try:
                downloaded = download_candidate(remote[0], dest)
                return {"status": "downloaded", "package_type": package_type, "selected": downloaded, "candidates": remote[:10]}
            except Exception as exc:
                return {"status": "download_failed", "package_type": package_type, "selected": remote[0], "error": str(exc), "candidates": remote[:10]}
        return {"status": "remote_candidate", "package_type": package_type, "selected": remote[0], "candidates": remote[:10]}
    return {
        "status": "waiting_input",
        "package_type": package_type,
        "reason": f"未找到 {package_type} 安装包。请补充到 /opt/ai-system-migration/packages/ 下，或配置可直接下载的官方 URL。",
        "searched_local_dirs": [str(p) for p in local_candidate_dirs(config)],
        "searched_remote_sources": configured_remote_sources(config),
    }


def resolution_report_for(packages: List[str], config: Dict[str, Any], download: bool = False) -> Dict[str, Any]:
    return {pkg: resolve_package(pkg, config, download=download) for pkg in packages}

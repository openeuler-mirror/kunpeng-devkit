from __future__ import annotations
import fnmatch
import io
import json
import os
import re
import shutil
import stat
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Iterable

from migration_common import (
    MigrationError,
    java_tool, run, run_shell,
)


OPEN_SOURCE_WHITELIST_VERSION = 4

# Nested JAR classification has two goals:
# 1. known third-party dependencies are not decompiled or sent to SQL migration;
# 2. business JARs, including unknown custom JARs, are still retained as candidates.
# "third_party" is intentionally broader than "open_source" because proprietary
# database drivers are third-party dependencies too and their internal SQL must not
# be rewritten as application SQL.
OPEN_SOURCE_GROUP_PREFIXES = (
    "org.springframework", "io.springfox", "org.apache", "org.slf4j", "ch.qos.logback",
    "com.fasterxml", "com.google", "com.googlecode", "io.netty",
    "org.mybatis", "com.baomidou", "org.hibernate", "org.apache.commons",
    "org.codehaus", "org.eclipse", "org.jboss", "org.aspectj",
    "org.quartz", "org.thymeleaf", "org.freemarker", "org.projectlombok",
    "org.jetbrains", "io.swagger", "org.springdoc", "redis.clients",
    "org.redisson", "com.zaxxer", "org.jsoup", "org.bouncycastle",
    "net.bytebuddy", "org.objenesis", "org.ow2.asm", "org.yaml",
    "jakarta", "javax", "org.flywaydb", "org.liquibase", "org.mapstruct",
    "com.github.jsqlparser", "net.sf.jsqlparser", "com.github.pagehelper",
    "com.alibaba", "cn.hutool", "com.github.oshi", "org.attoparser",
    "io.github.classgraph", "com.sun.jna", "net.java.dev.jna", "org.javassist",
    "org.dom4j", "org.unbescape", "org.webjars", "org.glassfish",
    "org.checkerframework", "nz.net.ultraq", "ognl",
)

DATABASE_DRIVER_GROUP_PREFIXES = (
    "com.mysql", "mysql", "org.postgresql", "org.mariadb", "org.xerial",
    "com.oracle", "oracle", "com.microsoft.sqlserver", "com.ibm.db2",
    "com.h2database", "org.hsqldb", "com.dameng",
)

OPEN_SOURCE_ARTIFACT_PATTERNS = (
    "spring-*", "springboot-*", "spring-boot-*", "springfox-*", "tomcat-*", "jackson-*",
    "slf4j-*", "logback-*", "netty-*", "mybatis-*", "mybatis-plus-*",
    "hibernate-*", "commons-*", "guava*", "gson*", "lombok*",
    "byte-buddy*", "asm-*", "snakeyaml*", "aspectj*", "quartz*",
    "thymeleaf*", "freemarker*", "swagger-*", "springdoc-*", "junit-*",
    "hamcrest-*", "mockito-*", "hikari*", "hutool-*", "fastjson*", "druid*",
    "jedis*", "redisson*", "jsqlparser*", "pagehelper*", "flyway-*", "liquibase-*",
    "oshi-core*", "attoparser*", "classgraph*", "jna*", "jna-platform*",
    "javassist*", "dom4j*", "unbescape*", "webjars-*", "checker-qual*", "ognl*",
)

DATABASE_DRIVER_ARTIFACT_PATTERNS = (
    "mysql-connector-*", "mysql-connector*", "postgresql*", "mariadb-java-client*",
    "ojdbc*", "oraclejdbc*", "mssql-jdbc*", "sqljdbc*", "db2jcc*", "h2-*",
    "hsqldb*", "sqlite-jdbc*", "dmjdbcdriver*", "dm-jdbc*", "dameng-jdbc*",
)

DATABASE_DRIVER_CLASS_PREFIXES = (
    "dm/jdbc/", "com/mysql/", "org/postgresql/", "org/mariadb/jdbc/",
    "oracle/jdbc/", "com/microsoft/sqlserver/jdbc/", "com/ibm/db2/",
    "org/h2/", "org/hsqldb/", "org/sqlite/",
)

def _pom_properties(jar_path: Path) -> dict[str, str]:
    metadata: dict[str, str] = {}
    try:
        with zipfile.ZipFile(jar_path) as zf:
            candidates = [
                name for name in zf.namelist()
                if name.startswith("META-INF/maven/") and name.endswith("/pom.properties")
            ]
            if not candidates:
                return metadata
            raw = zf.read(sorted(candidates)[0]).decode("utf-8", errors="replace")
            for line in raw.splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key.strip() in {"groupId", "artifactId", "version"}:
                    metadata[key.strip()] = value.strip()
    except (OSError, zipfile.BadZipFile, KeyError):
        return {}
    return metadata


def _group_matches(group_id: str, prefixes: tuple[str, ...]) -> bool:
    for prefix in prefixes:
        normalized = prefix.rstrip(".")
        if group_id == normalized or group_id.startswith(normalized + "."):
            return True
    return False


def _artifact_matches(values: list[str], patterns: tuple[str, ...]) -> str:
    for pattern in patterns:
        if any(value and fnmatch.fnmatch(value, pattern.lower()) for value in values):
            return pattern
    return ""


def _jar_has_class_prefix(jar_path: Path, prefixes: Iterable[str]) -> str:
    normalized = tuple(p.rstrip("/") + "/" for p in prefixes if p)
    if not normalized:
        return ""
    try:
        with zipfile.ZipFile(jar_path) as zf:
            for name in zf.namelist():
                if not name.endswith(".class") or name.startswith("META-INF/versions/"):
                    continue
                for prefix in normalized:
                    if name.startswith(prefix):
                        return prefix.rstrip("/")
    except (OSError, zipfile.BadZipFile):
        return ""
    return ""


def _business_root_from_parts(parts: tuple[str, ...]) -> str:
    """Build a stable organization-level package root from a class path.

    The root is derived from the application's own package layout.  Common
    reverse-domain forms such as ``com/company/...`` and ``cn/com/company/...``
    are handled without relying on any application or product name.
    """
    if len(parts) < 3:
        return ""
    first = parts[0].lower()
    second = parts[1].lower()
    if first == "cn" and second in {"com", "net", "org", "gov", "edu"}:
        return "/".join(parts[:3]) if len(parts) >= 4 else ""
    return "/".join(parts[:2])


def infer_business_package_roots(classes_dir: Path) -> list[str]:
    """Infer business package roots from classes packaged by the application.

    The result is a positive business profile used to compare nested JAR class
    paths and Maven groups.  No application-specific package or artifact name
    is embedded in the classifier.
    """
    counts: dict[str, int] = {}
    if not classes_dir.is_dir():
        return []
    for class_file in classes_dir.rglob("*.class"):
        try:
            rel = class_file.relative_to(classes_dir)
        except ValueError:
            continue
        parts = rel.parts
        if len(parts) < 3 or parts[0] == "META-INF":
            continue
        root = _business_root_from_parts(parts)
        if not root:
            continue
        counts[root] = counts.get(root, 0) + 1
    return [root for root, _ in sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:32]]


def _business_name_tokens(business_package_roots: Iterable[str]) -> list[str]:
    """Derive optional artifact-name hints from inferred package roots."""
    candidates: set[str] = set()
    generic = {
        "com", "org", "net", "io", "cn", "co", "dev", "app", "java",
        "javax", "jakarta", "spring", "company", "example",
    }
    for root in business_package_roots:
        parts = [part.lower() for part in str(root).split("/") if part]
        if not parts:
            continue
        for token in parts:
            if len(token) >= 3 and token not in generic:
                candidates.add(token)
    return sorted(candidates)


def _business_artifact_token(values: Iterable[str], business_package_roots: Iterable[str]) -> str:
    """Return a package-derived business hint found in a nested artifact name.

    Artifact names are only an auxiliary positive signal.  The primary signals
    remain class-package overlap and Maven-group overlap with the dynamically
    inferred application package profile.
    """
    for token in _business_name_tokens(business_package_roots):
        for value in values:
            normalized = re.sub(r"[^a-z0-9]+", "-", str(value).lower()).strip("-")
            if token == normalized or normalized.startswith(token + "-") or ("-" + token + "-") in ("-" + normalized + "-"):
                return token
    return ""


def classify_nested_jar(jar_path: Path, business_package_roots: Iterable[str] | None = None) -> dict[str, Any]:
    """Classify a direct nested JAR using positive business signals.

    When top-level business namespaces are available, an unknown nested JAR is
    no longer automatically treated as a business candidate.  It must match the
    application's inferred class namespace, Maven group, or a package-derived
    artifact-name hint.  ``BUSINESS_CANDIDATE`` is kept only as a fallback when
    the top-level archive does not provide enough classes to infer a business
    namespace.
    """
    metadata = _pom_properties(jar_path)
    group_id = metadata.get("groupId", "")
    artifact_id = metadata.get("artifactId", "")
    filename = jar_path.name
    values = [artifact_id.lower(), jar_path.stem.lower(), filename.lower()]
    business_roots = list(business_package_roots or [])

    driver_pattern = _artifact_matches(values, DATABASE_DRIVER_ARTIFACT_PATTERNS)
    driver_class = _jar_has_class_prefix(jar_path, DATABASE_DRIVER_CLASS_PREFIXES)
    if (group_id and _group_matches(group_id, DATABASE_DRIVER_GROUP_PREFIXES)) or driver_pattern or driver_class:
        reason = (
            f"database-driver-group:{group_id}" if group_id and _group_matches(group_id, DATABASE_DRIVER_GROUP_PREFIXES)
            else f"database-driver-artifact:{driver_pattern}" if driver_pattern
            else f"database-driver-class:{driver_class}"
        )
        classification = "THIRD_PARTY"
        open_source = False
        third_party = True
    else:
        business_match = _jar_has_class_prefix(jar_path, business_roots)
        group_path = group_id.replace(".", "/") if group_id else ""
        group_business_match = next(
            (root for root in business_roots if group_path == root or group_path.startswith(root + "/")),
            "",
        )
        open_pattern = _artifact_matches(values, OPEN_SOURCE_ARTIFACT_PATTERNS)
        if business_match or group_business_match:
            classification = "BUSINESS"
            open_source = False
            third_party = False
            reason = f"business-namespace:{business_match or group_business_match}"
        elif group_id and _group_matches(group_id, OPEN_SOURCE_GROUP_PREFIXES):
            classification = "THIRD_PARTY"
            open_source = True
            third_party = True
            reason = f"maven-group:{group_id}"
        elif open_pattern:
            classification = "THIRD_PARTY"
            open_source = True
            third_party = True
            reason = f"artifact-pattern:{open_pattern}"
        else:
            artifact_business_match = _business_artifact_token(values, business_roots)
            if artifact_business_match:
                classification = "BUSINESS"
                open_source = False
                third_party = False
                reason = f"business-artifact-token:{artifact_business_match}"
            elif business_roots:
                # The top-level application already gives us a reliable business
                # namespace.  A nested JAR with no matching namespace/name is much
                # more likely to be a dependency than application-owned code.
                classification = "THIRD_PARTY"
                open_source = False
                third_party = True
                reason = f"external-maven-group:{group_id}" if group_id else "no-business-signal"
            else:
                classification = "BUSINESS_CANDIDATE"
                open_source = False
                third_party = False
                reason = "business-namespace-unavailable"

    return {
        "file_name": filename,
        "group_id": group_id,
        "artifact_id": artifact_id,
        "version": metadata.get("version", ""),
        "classification": classification,
        "open_source": open_source,
        "third_party": third_party,
        "reason": reason,
    }


def nested_jar_candidates(
    unpacked: Path,
    layout: str,
    lib_dir: Path,
    business_package_roots: Iterable[str] | None = None,
) -> list[dict[str, Any]]:
    if layout not in {"WAR", "SPRING_BOOT_JAR"} or not lib_dir.is_dir():
        return []
    result: list[dict[str, Any]] = []
    used_ids: set[str] = set()
    for index, jar_path in enumerate(sorted(p for p in lib_dir.glob("*.jar") if p.is_file()), start=1):
        info = classify_nested_jar(jar_path, business_package_roots)
        slug = re.sub(r"[^A-Za-z0-9._-]+", "-", jar_path.stem).strip("-._") or f"jar-{index}"
        module_id = slug
        suffix = 2
        while module_id in used_ids:
            module_id = f"{slug}-{suffix}"
            suffix += 1
        used_ids.add(module_id)
        info.update({
            "module_id": module_id,
            "jar_path": str(jar_path.resolve()),
            "archive_path": jar_path.relative_to(unpacked).as_posix(),
        })
        result.append(info)
    return result

def safe_extract_zip(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with zipfile.ZipFile(archive) as zf:
        for item in zf.infolist():
            mode = (item.external_attr >> 16) & 0o170000
            if stat.S_ISLNK(mode):
                raise MigrationError("UNSAFE_ARCHIVE", f"Zip symlink is not allowed: {item.filename}")
            target = (destination / item.filename).resolve()
            if os.path.commonpath([str(root), str(target)]) != str(root):
                raise MigrationError("UNSAFE_ARCHIVE", f"Unsafe archive member: {item.filename}")
        zf.extractall(destination)

def rebuild_zip_with_replacement(data: bytes, path_parts: list[str], replacement: bytes) -> bytes:
    current = path_parts[0]
    source = io.BytesIO(data)
    target = io.BytesIO()
    found = False
    with zipfile.ZipFile(source, "r") as zin, zipfile.ZipFile(target, "w") as zout:
        for info in zin.infolist():
            item_data = zin.read(info.filename)
            if info.filename == current:
                found = True
                if len(path_parts) == 1:
                    item_data = replacement
                else:
                    item_data = rebuild_zip_with_replacement(item_data, path_parts[1:], replacement)
            zout.writestr(info, item_data)
    if not found:
        raise MigrationError("NATIVE_REPLACEMENT_NOT_FOUND", f"Archive entry not found: {'!/'.join(path_parts)}")
    return target.getvalue()

def rebuild_zip_with_mutation(
    data: bytes, path_parts: list[str], action: str, source_data: bytes | None
) -> bytes:
    current = path_parts[0]
    source = io.BytesIO(data)
    target = io.BytesIO()
    found = False
    with zipfile.ZipFile(source, "r") as zin, zipfile.ZipFile(target, "w") as zout:
        for info in zin.infolist():
            item_data = zin.read(info.filename)
            if info.filename == current:
                found = True
                if len(path_parts) == 1:
                    if action == "delete":
                        continue
                    if action in {"replace", "add"}:
                        if source_data is None:
                            raise MigrationError("INVALID_ARCHIVE_MUTATION", "source data is required")
                        item_data = source_data
                else:
                    item_data = rebuild_zip_with_mutation(item_data, path_parts[1:], action, source_data)
            zout.writestr(info, item_data)
        if not found and len(path_parts) == 1 and action == "add":
            if source_data is None:
                raise MigrationError("INVALID_ARCHIVE_MUTATION", "source data is required")
            zout.writestr(current, source_data)
            found = True
    if not found:
        raise MigrationError(
            "ARCHIVE_MUTATION_TARGET_NOT_FOUND",
            f"Archive entry not found for {action}: {'!/'.join(path_parts)}",
        )
    return target.getvalue()

def materialize_source(item: dict[str, Any], work_dir: Path, log_path: Path) -> Path:
    direct = item.get("source_file") or item.get("replacement_file")
    if direct:
        path = Path(str(direct)).expanduser().resolve()
        if not path.is_file():
            raise MigrationError("ARCHIVE_MUTATION_SOURCE_MISSING", f"File not found: {path}")
        return path
    url = item.get("download_url")
    if url:
        name = str(item.get("download_name") or Path(str(url).split("?", 1)[0]).name or "download.bin")
        target = work_dir / "downloads" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            urllib.request.urlretrieve(str(url), target)
        return target
    build_command = item.get("build_command")
    output_file = item.get("build_output")
    if build_command and output_file:
        run_shell(str(build_command), log_path, cwd=work_dir)
        path = Path(str(output_file)).expanduser()
        if not path.is_absolute():
            path = work_dir / path
        path = path.resolve()
        if not path.is_file():
            raise MigrationError("BUILD_OUTPUT_MISSING", f"Build output not found: {path}")
        return path
    raise MigrationError("INVALID_ARCHIVE_MUTATION", f"No source_file, download_url, or build_command: {item}")

def apply_archive_mutations(
    package: Path, mutations: list[dict[str, Any]], work_dir: Path, log_path: Path
) -> list[dict[str, str]]:
    if not mutations:
        return []
    data = package.read_bytes()
    applied: list[dict[str, str]] = []
    for item in mutations:
        action = str(item.get("action") or "replace").lower()
        archive_path = str(item.get("archive_path") or "")
        if action not in {"add", "replace", "delete"} or not archive_path:
            raise MigrationError("INVALID_ARCHIVE_MUTATION", f"Invalid archive mutation: {item}")
        source_data = None
        source_path = None
        if action != "delete":
            source_path = materialize_source(item, work_dir, log_path)
            source_data = source_path.read_bytes()
        data = rebuild_zip_with_mutation(data, archive_path.split("!/"), action, source_data)
        applied.append({
            "action": action,
            "archive_path": archive_path,
            "source_file": str(source_path) if source_path else "",
        })
    package.write_bytes(data)
    with log_path.open("a", encoding="utf-8") as fh:
        for item in applied:
            fh.write(json.dumps(item, ensure_ascii=False) + "\n")
    return applied

def detect_layout(unpacked: Path, package: Path) -> tuple[str, Path, Path]:
    if (unpacked / "WEB-INF/classes").is_dir():
        return "WAR", unpacked / "WEB-INF/classes", unpacked / "WEB-INF/lib"
    if (unpacked / "BOOT-INF/classes").is_dir():
        return "SPRING_BOOT_JAR", unpacked / "BOOT-INF/classes", unpacked / "BOOT-INF/lib"
    if package.suffix.lower() == ".jar":
        return "JAR", unpacked, unpacked / "lib"
    raise MigrationError(
        "UNSUPPORTED_PACKAGE_LAYOUT",
        "Only WAR, Spring Boot JAR, or a regular JAR with class files can be automatically rebuilt",
    )

def copy_resources(classes_dir: Path, resources_root: Path, *, exclude_meta_inf_maven: bool = False) -> None:
    if resources_root.exists():
        shutil.rmtree(resources_root)
    resources_root.mkdir(parents=True, exist_ok=True)
    for source in classes_dir.rglob("*"):
        if source.is_dir() or source.suffix == ".class":
            continue
        rel = source.relative_to(classes_dir)
        if exclude_meta_inf_maven and len(rel.parts) >= 2 and rel.parts[0] == "META-INF" and rel.parts[1] == "maven":
            continue
        target = resources_root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

def class_prefix(layout: str) -> Path:
    if layout == "WAR":
        return Path("WEB-INF/classes")
    if layout == "SPRING_BOOT_JAR":
        return Path("BOOT-INF/classes")
    return Path("")


def prepare_overlay(
    changes: list[dict[str, str]],
    patch_root: Path,
    compiled_dir: Path,
    overlay: Path,
    layout: str,
) -> list[str]:
    if overlay.exists():
        shutil.rmtree(overlay)
    overlay.mkdir(parents=True)
    prefix = class_prefix(layout)
    updated: list[str] = []
    for class_file in compiled_dir.rglob("*.class") if compiled_dir.exists() else []:
        rel = class_file.relative_to(compiled_dir)
        target = overlay / prefix / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(class_file, target)
        updated.append((prefix / rel).as_posix())
    for change in changes:
        path = change["path"]
        if change["status"] == "D":
            raise MigrationError("UNSUPPORTED_PATCH_DELETE", f"Deletion is not supported: {path}")
        if path.startswith("src/main/resources/"):
            rel = Path(path).relative_to("src/main/resources")
            source = patch_root / path
            target = overlay / prefix / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            updated.append((prefix / rel).as_posix())
        elif path.startswith("src/main/java/"):
            continue
        elif path in {"mapping.json", "compile-fixes.json"}:
            continue
        else:
            raise MigrationError("UNSUPPORTED_PATCH_PATH", f"Patch changed an unsupported path: {path}")
    return sorted(set(updated))

def update_archive(package: Path, output: Path, overlay: Path, jdk_home: str | None, log_dir: Path) -> None:
    shutil.copy2(package, output)
    if not any(overlay.rglob("*")):
        return
    jar = java_tool(jdk_home, "jar")
    run([jar, "--update", "--file", str(output), "-C", str(overlay), "."], log_dir / "jar-update.log")
    run([jar, "--list", "--file", str(output)], log_dir / "jar-list.log")



def prepare_nested_overlay(
    changes: list[dict[str, str]],
    patch_root: Path,
    module_id: str,
    compiled_dir: Path,
    overlay: Path,
) -> list[str]:
    if overlay.exists():
        shutil.rmtree(overlay)
    overlay.mkdir(parents=True, exist_ok=True)
    module_prefix = f"nested/{module_id}/"
    java_prefix = module_prefix + "src/main/java/"
    resources_prefix = module_prefix + "src/main/resources/"
    updated: list[str] = []
    if compiled_dir.exists():
        for class_file in compiled_dir.rglob("*.class"):
            rel = class_file.relative_to(compiled_dir)
            target = overlay / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(class_file, target)
            updated.append(rel.as_posix())
    for change in changes:
        path = change["path"]
        if not path.startswith(module_prefix):
            continue
        if change["status"] == "D":
            raise MigrationError("UNSUPPORTED_PATCH_DELETE", f"Deletion is not supported: {path}")
        if path.startswith(resources_prefix):
            rel = Path(path[len(resources_prefix):])
            source = patch_root / path
            target = overlay / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            updated.append(rel.as_posix())
        elif path.startswith(java_prefix):
            continue
        else:
            raise MigrationError("UNSUPPORTED_PATCH_PATH", f"Patch changed an unsupported nested path: {path}")
    return sorted(set(updated))

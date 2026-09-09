#!/usr/bin/env python3
"""
transform_plan.py — 将 migration-plan.json 转换为内部统一格式

用法: python3 transform_plan.py <plan_file> <plan_base_dir>
输出: 紧凑 JSON 数组，保留路由 id，含标准化 type、源/目标版本、部署目录、配置产物和安装包信息。

只校验本转换器消费的输入，不下载文件、不替代上游完整计划校验。
路径解析仅用于安全判定，正常输出保留逻辑路径、URL 原文和已有空值语义。
"""
import ipaddress
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


# scripts/lib/transform_plan.py → 模块根 = scripts/lib 上两级（middleware-migration/）
LIB_DIR = Path(__file__).resolve().parent
MW_ROOT = LIB_DIR.parent.parent
REGISTRY_FILE = MW_ROOT / "config" / "middleware_registry.json"


def load_product_aliases():
    """读取 registry 中供 source/target.product 共用的产品名映射。"""
    try:
        with open(REGISTRY_FILE, 'r', encoding='utf-8') as f:
            aliases = json.load(f).get('product_aliases', {})
    except (OSError, json.JSONDecodeError):
        return {}
    return aliases if isinstance(aliases, dict) else {}


PRODUCT_ALIASES = load_product_aliases()


def normalize_type(orig):
    """标准化中间件类型名"""
    if not orig:
        return ""
    mapping = {
        "Apache Tomcat": "tomcat",
        "Nginx": "nginx",
        "Elasticsearch": "elasticsearch",
        "Redis": "redis",
        "RabbitMQ": "rabbitmq",
        "Nacos": "nacos",
        "RocketMQ": "rocketmq",
        "ZooKeeper": "zookeeper",
        "Kafka": "kafka",
        "Docker": "docker",
        "OpenJDK": "openjdk",
        "OpenJRE": "bisenjre",
        "Bisheng OpenJDK": "openjdk",
        "BiSheng OpenJDK": "openjdk",
        "BiShengJDK": "openjdk",
        "BishengJDK": "openjdk",
        "JDK / JRE": "openjdk",
        "IBM JDK": "ibmjdk",
        "Oracle JDK": "oraclejdk",
        "TongWeb": "tongweb",
    }
    mapping.update(PRODUCT_ALIASES)
    if orig in mapping:
        return mapping[orig]
    compact = re.sub(r'\s+', '', orig)
    if compact != orig:
        for key, value in mapping.items():
            if re.sub(r'\s+', '', key) == compact:
                return value
    result = orig.lower()
    result = re.sub(r'^apache ', '', result)
    return result


def _fail(field, reason):
    """错误只描述字段和原因，不回显 URL 凭据或其他原始输入。"""
    raise ValueError("{} {}".format(field, reason))


def _has_control(text):
    return any(ord(ch) < 32 or 127 <= ord(ch) <= 159 for ch in text)


def _require_type(value, expected, field):
    if not isinstance(value, expected):
        _fail(field, "must be a {}".format(expected.__name__))
    return value


def _validate_path_segment(value, field):
    """只允许一个非空路径段；冒号也禁止，避免 Windows 盘符/备用数据流。"""
    _require_type(value, str, field)
    if not value.strip() or value in ('.', '..'):
        _fail(field, "must be a non-empty path segment other than . or ..")
    if '/' in value or '\\' in value or ':' in value or Path(value).is_absolute():
        _fail(field, "must not contain a path separator, drive or stream name")
    if _has_control(value):
        _fail(field, "must not contain control characters")
    return value


def _validate_identity(value, field):
    # 保留已有整数 id 转字符串的行为，不把 list/dict/bool 伪装成正常 id。
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        _fail(field, "must be a string or integer identifier")
    return _validate_path_segment(str(value or ''), field)


def _build_migration_root(plan):
    target_env = _require_type(
        plan.get('target_environment', {}), dict, 'target_environment')
    work_dir = target_env.get('migration_work_dir')
    if work_dir is not None:
        _require_type(work_dir, str, 'target_environment.migration_work_dir')
        if _has_control(work_dir):
            _fail('target_environment.migration_work_dir',
                  "must not contain control characters")
    migration_id = plan.get('migration_id')
    if migration_id is not None and (
        isinstance(migration_id, bool) or not isinstance(migration_id, (str, int))
    ):
        _fail('migration_id', "must be a string or integer identifier")
    base = Path(work_dir or '')
    if not base.is_absolute() or not migration_id:
        # 保留上游基础条件和退出码，SYSTEM_REPOSITORY 也不能绕过。
        sys.stderr.write(
            "invalid plan: target_environment.migration_work_dir (absolute) and migration_id are required\n"
        )
        sys.exit(2)
    # 非空不代表安全：继续拒绝 ../、盘符、控制字符等非法路径段。
    migration_id = _validate_identity(migration_id, 'migration_id')
    return base / migration_id


def _resolve_child(path, parent, field):
    """同时检查符号链接落点与目录边界；不改变返回给 Shell 的逻辑路径。"""
    try:
        resolved = path.resolve()
        relative = resolved.relative_to(parent)
    except (OSError, RuntimeError, ValueError):
        _fail(field, "path escapes its allowed directory or cannot be resolved")
    if relative == Path('.'):
        _fail(field, "path must be below, not equal to, its allowed directory")
    return resolved


def _safe_package_path(root, middleware_id, file_name, idx_path):
    field = '{}.packages[0].file_name'.format(idx_path)
    _validate_path_segment(file_name, field)
    try:
        base = root.parent.resolve()
    except (OSError, RuntimeError, ValueError):
        _fail('target_environment.migration_work_dir', "cannot be resolved")
    # 连迁移根和 packages 本身的外指链接也检查，防止允许根随链接一起外移。
    resolved_root = _resolve_child(root, base, 'migration_id')
    packages = root / 'packages'
    resolved_packages = _resolve_child(packages, resolved_root, field)
    candidate = packages / middleware_id / file_name
    _resolve_child(candidate, resolved_packages, field)
    return str(candidate)


def _validate_url_host(netloc, hostname, field):
    """区分 IPv6 与域名，不用域名白名单限制合法的内网下载来源。"""
    if netloc.startswith('['):
        end = netloc.find(']')
        suffix = netloc[end + 1:]
        if end < 0 or (suffix and not re.fullmatch(r':[0-9]+', suffix)):
            _fail(field, "has an invalid IPv6 authority")
        address, separator, zone = netloc[1:end].partition('%25')
        if separator and not re.fullmatch(r'[A-Za-z0-9_.~-]+', zone):
            _fail(field, "has an invalid IPv6 zone identifier")
        # 原始 % 不作为未编码的 zone 接受；必须使用 URL 中的 %25。
        if '%' in address:
            _fail(field, "has an invalid IPv6 address")
        try:
            ipaddress.IPv6Address(address)
        except ValueError:
            _fail(field, "has an invalid IPv6 address")
        return
    if '[' in netloc or ']' in netloc or netloc.count(':') > 1:
        _fail(field, "has an invalid hostname or unbracketed IPv6 address")
    try:
        ascii_host = hostname.encode('idna').decode('ascii')
    except UnicodeError:
        _fail(field, "has an invalid hostname")
    labels = ascii_host.split('.')
    # 保留单标签内网名及内部使用的下划线；禁止空标签、非法字符和过长标签。
    if len(ascii_host) > 253 or any(
        not re.fullmatch(r'[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?', label)
        for label in labels
    ):
        _fail(field, "has an invalid hostname")
    if '.' in ascii_host and re.fullmatch(r'[0-9.]+', ascii_host):
        try:
            ipaddress.IPv4Address(ascii_host)
        except ValueError:
            _fail(field, "has an invalid IPv4 address")


def _validate_download_url(value, field):
    # 空 URL/null 的透传不是完整计划批准；包来源与准备状态仍由上游判断。
    if value is None or value == '':
        return value
    _require_type(value, str, field)
    if _has_control(value) or any(ch.isspace() for ch in value) or '\\' in value:
        _fail(field, "must not contain controls, whitespace or backslashes")
    # 仅为解析临时替换；输出不展开、不重新拼装 URL。
    probe = value.replace('${TARGET_VERSION}', '0.0.0')
    try:
        parts = urlsplit(probe)
        hostname = parts.hostname
        port = parts.port
    except ValueError:
        _fail(field, "has an invalid URL authority or port")
    if parts.scheme != 'https':
        _fail(field, "must be an HTTPS URL")
    if not parts.netloc or not hostname:
        _fail(field, "must contain a hostname")
    if '@' in parts.netloc:
        _fail(field, "must not contain user information")
    if parts.netloc.endswith(':') or (port is not None and not 1 <= port <= 65535):
        _fail(field, "must have a port in the range 1-65535")
    _validate_url_host(parts.netloc, hostname, field)
    return value


def _load_plan(plan_file):
    try:
        with open(plan_file, 'r', encoding='utf-8-sig') as stream:
            plan = json.load(stream)
    except OSError:
        _fail('plan_file', "cannot be read")
    except UnicodeError:
        _fail('plan_file', "must be UTF-8 encoded")
    except json.JSONDecodeError as exc:
        _fail('plan_file', "contains invalid JSON at line {}, column {}".format(
            exc.lineno, exc.colno))
    return _require_type(plan, dict, 'plan')


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("用法: transform_plan.py <plan_file> <plan_base_dir>\n")
        sys.exit(2)

    plan_file = sys.argv[1]
    plan_base = sys.argv[2]

    plan = _load_plan(plan_file)

    # route.middleware 已包含所有中间件项（含 JDK）
    route = _require_type(plan.get('route', {}), dict, 'route')
    middlewares = _require_type(route.get('middleware', []), list, 'route.middleware')
    migration_root = _build_migration_root(plan)

    result = []
    for index, mw in enumerate(middlewares):
        idx_path = 'route.middleware[{}]'.format(index)
        _require_type(mw, dict, idx_path)
        mw_id = _validate_identity(mw.get('id'), idx_path + '.id')
        source = _require_type(mw.get('source', {}), dict, idx_path + '.source')
        target = _require_type(mw.get('target', {}), dict, idx_path + '.target')
        for name, component in (('source', source), ('target', target)):
            product = component.get('product')
            if product is not None:
                _require_type(product, str, '{}.{}.product'.format(idx_path, name))
        packages = _require_type(mw.get('packages', []), list, idx_path + '.packages')
        pkg = packages[0] if packages else {}
        pkg_field = idx_path + '.packages[0]'
        _require_type(pkg, dict, pkg_field)
        source_type = _require_type(
            pkg.get('source_type', ''), str, pkg_field + '.source_type')
        file_name = pkg.get('file_name', '')
        if 'file_name' in pkg:
            _validate_path_segment(file_name, pkg_field + '.file_name')
        download_url = _validate_download_url(
            pkg.get('download_url', ''), pkg_field + '.download_url')
        license_path = pkg.get('license_path', '')
        if license_path is not None:
            _require_type(license_path, str, pkg_field + '.license_path')

        prepared_package = ''
        if pkg and source_type != 'SYSTEM_REPOSITORY':
            prepared_package = _safe_package_path(migration_root, mw_id, file_name, idx_path)

        item = {
            'id': mw_id,
            'type': normalize_type(target.get('product') or source.get('product') or ''),
            'source_product': source.get('product', ''),
            'target_product': target.get('product', ''),
            'current_version': source.get('version', '') or 'unknown',
            'target_version': target.get('version', ''),
            'source_dir': source.get('location', ''),
            'artifact_base_dir': plan_base,
            'config_paths': source.get('artifact_paths', []),
            'download_url': download_url,
            'local_package_path': prepared_package,
            'package_file_name': file_name,
            'source_type': source_type,
            'license_path': license_path,
        }
        result.append(item)

    # JDK 优先排序，Java 中间件可直接复用已迁移的运行时
    jdk_types = {'openjdk', 'ibmjdk', 'oraclejdk', 'bisenjre', 'jdk'}
    result.sort(key=lambda item: 0 if item.get('type') in jdk_types else 1)

    print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        # 输入错误均为 ASCII 字段级消息，避免改变正常 stdout 的编码契约。
        sys.stderr.write(str(error) + '\n')
        sys.exit(1)

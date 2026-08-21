#!/usr/bin/env python3
"""
transform_plan.py — 将 migration-plan.json 转换为内部统一格式

用法: python3 transform_plan.py <plan_file> <plan_base_dir>
输出: 紧凑 JSON 数组，保留路由 id，含标准化 type、源/目标版本、部署目录、配置产物和安装包信息。
"""
import json
import re
import sys
from pathlib import Path


REGISTRY_FILE = Path(__file__).resolve().parents[2] / "config" / "middleware_registry.json"


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


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("用法: transform_plan.py <plan_file> <plan_base_dir>\n")
        sys.exit(2)

    plan_file = sys.argv[1]
    plan_base = sys.argv[2]

    with open(plan_file, 'r', encoding='utf-8-sig') as f:
        plan = json.load(f)

    # route.middleware 已包含所有中间件项（含 JDK）
    middlewares = plan.get('route', {}).get('middleware', [])
    migration_base = Path(str(plan.get('target_environment', {}).get('migration_work_dir') or ''))
    migration_id = str(plan.get('migration_id') or '')
    migration_root = migration_base / migration_id if migration_base.is_absolute() and migration_id else None

    result = []
    for mw in middlewares:
        source = mw.get('source', {})
        target = mw.get('target', {})
        packages = mw.get('packages', [])
        pkg = packages[0] if packages else {}

        prepared_package = ''
        if pkg and pkg.get('source_type') != 'SYSTEM_REPOSITORY' and migration_root is not None:
            prepared_package = str(migration_root / 'packages' / str(mw.get('id') or '') / str(pkg.get('file_name') or ''))

        item = {
            'id': str(mw.get('id') or ''),
            'type': normalize_type(target.get('product') or source.get('product') or ''),
            'source_product': source.get('product', ''),
            'target_product': target.get('product', ''),
            'current_version': source.get('version', ''),
            'target_version': target.get('version', ''),
            'source_dir': source.get('location', ''),
            'artifact_base_dir': plan_base,
            'config_paths': source.get('artifact_paths', []),
            'download_url': pkg.get('download_url', ''),
            'local_package_path': prepared_package,
            'package_file_name': pkg.get('file_name', ''),
            'source_type': pkg.get('source_type', ''),
            'license_path': pkg.get('license_path', ''),
        }
        result.append(item)

    # JDK 优先排序，Java 中间件可直接复用已迁移的运行时
    jdk_types = {'openjdk', 'ibmjdk', 'oraclejdk', 'bisenjre', 'jdk'}
    result.sort(key=lambda item: 0 if item.get('type') in jdk_types else 1)

    print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))


if __name__ == '__main__':
    main()

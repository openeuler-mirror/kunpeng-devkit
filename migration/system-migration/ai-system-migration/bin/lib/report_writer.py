#!/usr/bin/env python3
"""Report writer for AI System Migration Skill."""
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

from .interaction_bus import redact


def write_json(path: str | Path, data: Any) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(redact(data), ensure_ascii=False, indent=2), encoding="utf-8")


def bullet(items: List[Any]) -> str:
    if not items:
        return "- 无\n"
    lines = []
    for item in items:
        if isinstance(item, dict):
            lines.append(f"- `{item.get('name') or item.get('path') or item.get('phase') or 'item'}`：{json.dumps(redact(item), ensure_ascii=False)}")
        else:
            lines.append(f"- {item}")
    return "\n".join(lines) + "\n"


def markdown_report(data: Dict[str, Any]) -> str:
    generated = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    analysis = data.get("scan_analysis", {})
    route = data.get("route_plan", {})
    risks = data.get("risks", [])
    manual = data.get("manual_confirm_items", [])
    return f"""# AI 系统迁移报告

生成时间：{generated}

## 1. 迁移结论

- 应用类型：Java
- 目标架构：ARM / aarch64
- 默认路线：OpenJDK ARM，Tomcat -> 东方通，Resin -> Resin ARM，数据库 -> 达梦 DM
- 当前状态：{data.get('status', 'unknown')}

## 2. 源端扫描范围

- 扫描目录：{data.get('source_scan', {}).get('scan_dir', '未知')}
- 输出目录：{data.get('source_scan', {}).get('output_dir', '未知')}
- 结果包：{data.get('source_scan', {}).get('result_archive', '未知')}

## 3. 应用部署结构

### 运行中应用包候选

{bullet(analysis.get('runtime_apps', []))}

### 运行中组件

{bullet(analysis.get('components', {}).get('running', []))}

### 磁盘识别组件

{bullet(analysis.get('components', {}).get('detected', []))}

## 4. 源码路径识别结果

{bullet(analysis.get('source_candidates', []))}

## 5. 迁移路线

```json
{json.dumps(redact(route), ensure_ascii=False, indent=2)}
```

## 6. 中间件迁移结果

```json
{json.dumps(redact(data.get('middleware', {})), ensure_ascii=False, indent=2)}
```

## 7. 数据库迁移结果

```json
{json.dumps(redact(data.get('database', {})), ensure_ascii=False, indent=2)}
```

## 8. 应用改造结果

```json
{json.dumps(redact(data.get('application_transform', {})), ensure_ascii=False, indent=2)}
```

## 9. 启动验证结果

```json
{json.dumps(redact(data.get('deploy_verify', {})), ensure_ascii=False, indent=2)}
```

## 10. 风险项

{bullet(risks)}

## 11. 人工确认项

{bullet(manual)}

## 12. 回滚建议

- 保留源端原始环境，不在源端执行破坏性修改。
- 目标端所有覆盖动作前备份原配置和原应用包。
- 应用包改造后保留原始 Jar/WAR/EAR 及 SHA256。
- 数据库迁移前保留源库导出文件或 DTS 迁移任务配置。

## 13. 下一步建议

- 补齐所有人工确认项。
- 对数据库对象迁移结果做数量和抽样校验。
- 对核心业务接口做功能验证。
- 对中间件端口、JVM 参数、连接池参数做性能基线校验。
"""


def write_report(output_dir: str | Path, data: Dict[str, Any]) -> Dict[str, str]:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    md_path = output_dir / "migration-report.md"
    json_path = output_dir / "migration-report.json"
    md_path.write_text(markdown_report(redact(data)), encoding="utf-8")
    write_json(json_path, data)
    return {"markdown": str(md_path), "json": str(json_path)}

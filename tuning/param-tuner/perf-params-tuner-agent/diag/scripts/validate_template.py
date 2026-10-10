#!/usr/bin/env python3
"""模板格式校验脚本 — 对 task_xxx_System.yaml 和 param_xxx_System.yaml 做全量格式/结构校验。

本脚本负责所有格式类检查，agent 无需再判断格式问题。
agent 在拿到脚本输出后，只需关注语义级问题：
  - Task YAML: run_test 脚本是否可执行
  - Param YAML: 参数范围是否与当前环境匹配

用法:
    python3 validate_template.py <task_yaml> [param_yaml]
    python3 validate_template.py --task task_Redis_System.yaml --param param_Redis_System.yaml
    python3 validate_template.py --task task_Redis_System.yaml   # 仅校验 task
    python3 validate_template.py --param param_Redis_System.yaml  # 仅校验 param
    python3 validate_template.py --task ... --param ... --summary  # 紧凑输出（供 agent 解析）

输出:
    默认: 人类可读报告
    --summary: 紧凑文本（供 agent 快速解析）
    --json: JSON 格式（供程序化处理）
    返回码: 0=通过, 1=有错误, 2=仅有警告
"""

import sys
import os
import argparse
import json
import re
from dataclasses import dataclass, field, asdict
from typing import Any, Optional

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)


# ── 数据模型 ──────────────────────────────────────────────

@dataclass
class CheckResult:
    """单条校验结果"""
    severity: str       # "error" | "warning" | "info"
    rule_id: str        # 规则编号 (如 A1, B2, C1)
    message: str        # 描述
    file_type: str = ""  # "task" | "param" | "cross"
    auto_fixed: bool = False


@dataclass
class FileReport:
    """单个文件的校验报告"""
    file_path: str
    file_type: str  # "task" | "param"
    results: list = field(default_factory=list)
    parse_error: Optional[str] = None
    raw_text: str = ""  # 原始文件文本（用于格式检查）

    @property
    def error_count(self):
        return sum(1 for r in self.results if r.severity == "error" and not r.auto_fixed)

    @property
    def warning_count(self):
        return sum(1 for r in self.results if r.severity == "warning")

    @property
    def info_count(self):
        return sum(1 for r in self.results if r.severity == "info")

    @property
    def fixed_count(self):
        return sum(1 for r in self.results if r.auto_fixed)

    def add(self, severity, rule_id, message, auto_fixed=False):
        self.results.append(CheckResult(
            severity=severity, rule_id=rule_id, message=message,
            file_type=self.file_type, auto_fixed=auto_fixed
        ))


# ── Task YAML 校验 ────────────────────────────────────────

REQUIRED_TOP_FIELDS = ["template_type", "hosts_list", "configs", "assign_params",
                       "set_up", "round_set_up", "run_test", "round_tear_down", "tear_down"]

REQUIRED_CONFIG_FIELDS = {
    "rounds": (int,),
    "maximum_consecutive_failures": (int,),
    "algorithm": (str,),
    "random_initial_ratio": (int, float),
    "performance_info": (str,),
    "tuning_direction": (str,),
}

REQUIRED_PARAM_GROUP_FIELDS = ["name", "enable"]

RUNTIME_PLACEHOLDERS = ["<kat_name>", "<kat_value>", "<kat_suffix>"]

VARIABLE_PLACEHOLDERS = ["{app_exe_path}", "{app_config_path}", "{app_data_path}",
                         "{app_port}", "{timestamp}"]

# 需要用块标量格式的 cmd 字段路径
CMD_FIELDS = ["query_cmd", "assign_cmd", "backup_cmd", "recover_cmd", "execute_after_assign"]


def validate_task_yaml(report: FileReport, data: dict):
    """校验 task YAML — 全部格式/结构检查"""
    # A1: 顶级字段
    for f in REQUIRED_TOP_FIELDS:
        if f not in data:
            report.add("error", "A1", f"缺少顶级字段: {f}")

    if "template_type" not in data:
        return  # 结构严重缺失，无法继续

    # A2: configs 子字段
    configs = data.get("configs", {})
    if not isinstance(configs, dict):
        report.add("error", "A2", "configs 不是有效 map")
        configs = {}
    for field_name, expected_types in REQUIRED_CONFIG_FIELDS.items():
        if field_name not in configs:
            report.add("error", "A2", f"configs 缺少字段: {field_name}")
        elif not isinstance(configs[field_name], expected_types):
            report.add("error", "A2",
                       f"configs.{field_name} 类型错误: 期望 {expected_types}, "
                       f"实际 {type(configs[field_name]).__name__}")

    # B1: template_type
    tt = data.get("template_type", "")
    if tt and tt != "custom":
        report.add("error", "B1", f"template_type 应为 'custom', 实际为 '{tt}'")

    # B2: algorithm
    alg = configs.get("algorithm", "")
    if alg and alg != "HPO":
        report.add("error", "B2", f"algorithm 应为 'HPO', 实际为 '{alg}'")

    # B3: tuning_direction
    td = configs.get("tuning_direction", "")
    if td and td not in ("high", "low"):
        report.add("error", "B3", f"tuning_direction 应为 'high' 或 'low', 实际为 '{td}'")

    # B4: rounds
    rounds = configs.get("rounds")
    if rounds is not None:
        if not isinstance(rounds, int) or rounds <= 0:
            report.add("error", "B4", f"rounds 应为正整数, 实际为 {rounds}")
        elif rounds < 10:
            report.add("warning", "B4", f"rounds={rounds}, 建议至少 30 轮")
        elif rounds < 30:
            report.add("info", "B4", f"rounds={rounds}, 推荐 >= 30")

    # B5: random_initial_ratio
    rir = configs.get("random_initial_ratio")
    if rir is not None:
        if isinstance(rir, (int, float)):
            if rir < 0 or rir > 1:
                report.add("error", "B5", f"random_initial_ratio 应在 [0,1], 实际为 {rir}")

    # B6: maximum_consecutive_failures
    mcf = configs.get("maximum_consecutive_failures")
    if mcf is not None:
        if not isinstance(mcf, int) or mcf <= 0:
            report.add("error", "B6", f"maximum_consecutive_failures 应为正整数, 实际为 {mcf}")

    # B7: performance_info
    pi = configs.get("performance_info", "")
    if pi == "":
        report.add("error", "B7", "performance_info 为空字符串")

    # A3: assign_params
    assign_params = data.get("assign_params", [])
    if not assign_params:
        report.add("error", "A3", "assign_params 为空, 至少需要一个参数组")
    else:
        _validate_assign_params(report, assign_params)

    # C1: 块标量格式检查（读原始文本）
    _check_block_scalar_format(report, data)

    # C3: 命令非空
    for section in ["set_up", "round_set_up", "round_tear_down", "tear_down"]:
        section_data = data.get(section, [])
        if not section_data:
            report.add("warning", "C3", f"{section} 为空")
        else:
            for item in section_data:
                if isinstance(item, dict):
                    cmd = item.get("cmd", "")
                    if not cmd or (isinstance(cmd, str) and cmd.strip() == ""):
                        report.add("warning", "C3", f"{section} 中存在空 cmd")

    # run_test 非空
    run_test = data.get("run_test", [])
    if not run_test:
        report.add("error", "C3", "run_test 为空")
    else:
        _validate_run_test_wrapper(report, run_test)

    # D1: 占位符检查
    _check_placeholders(report, data)

    # E: host_name 规则
    _check_host_name_rules(report, data)


def _validate_assign_params(report: FileReport, assign_params: list):
    """校验 assign_params 条目结构"""
    has_enabled = False
    for i, param_group in enumerate(assign_params):
        if not isinstance(param_group, dict):
            report.add("error", "A3", f"assign_params[{i}] 不是有效 map")
            continue

        # 必需字段
        for f in REQUIRED_PARAM_GROUP_FIELDS:
            if f not in param_group:
                report.add("error", "A3", f"assign_params[{i}] 缺少字段: {f}")

        name = param_group.get("name", "")
        enable = param_group.get("enable", False)

        if enable:
            has_enabled = True

        # 应用参数组（非 System/uarch）enable=True 时必须有完整命令
        is_app_group = name not in ("System", "Kunpeng uarch")
        if is_app_group and enable:
            for cmd_field in CMD_FIELDS:
                cmds = param_group.get(cmd_field, [])
                if not cmds:
                    report.add("error", "F1",
                               f"assign_params[{i}] ({name}) 的 {cmd_field} 为空")
                else:
                    for cmd_item in cmds:
                        if isinstance(cmd_item, dict):
                            cmd_text = cmd_item.get("cmd", "")
                            if not cmd_text or (isinstance(cmd_text, str) and cmd_text.strip() == ""):
                                report.add("error", "F1",
                                           f"assign_params[{i}] ({name}) 的 {cmd_field} 中 cmd 为空")
                        elif isinstance(cmd_item, str) and not cmd_item.strip():
                            report.add("error", "F1",
                                       f"assign_params[{i}] ({name}) 的 {cmd_field} 中 cmd 为空")

    if not has_enabled:
        report.add("error", "F1", "assign_params 中没有 enable=True 的参数组")


def _check_block_scalar_format(report: FileReport, data: dict):
    """通过原始文本检查 cmd 是否使用 | 块标量格式"""
    raw = report.raw_text
    if not raw:
        return

    # 检查所有 cmd: 后面是否跟了 | 或 > 块标量
    # 匹配模式: cmd: 后面直接跟引号字符串（非块标量）
    lines = raw.split("\n")
    for line_num, line in enumerate(lines, 1):
        stripped = line.strip()
        # 匹配 "cmd:" 后跟引号字符串而非 |
        if re.match(r'^\s*cmd:\s*["\']', line):
            # cmd: "..." 或 cmd: '...' — 不是块标量
            report.add("error", "C1",
                       f"第 {line_num} 行: cmd 应使用 | 块标量格式, 不应用引号字符串: {stripped[:60]}...")


def _validate_run_test_wrapper(report: FileReport, run_test: list):
    """校验 run_test 最后一项的 benchmark 包装器结构"""
    last_item = run_test[-1]
    if not isinstance(last_item, dict):
        report.add("error", "C2", "run_test 最后一项不是有效 map")
        return

    cmd = last_item.get("cmd", "")
    if not cmd:
        report.add("error", "C2", "run_test 最后一项 cmd 为空")
        return

    if not isinstance(cmd, str):
        cmd = str(cmd)

    # C2: benchmark 包装器 5 要素
    checks = [
        ("output=$(", "output 捕获结构 (output=$( ... ))"),
        ("ne 0", "错误处理 (if [ $? -ne 0 ])"),
        ("result=$(echo", "指标提取 (result=$(echo ...))"),
        ('-z "$result"', "空值检查 (if [ -z \"$result\" ])"),
        ('echo "$result"', "最终输出 (echo \"$result\")"),
    ]

    for pattern, desc in checks:
        if pattern not in cmd:
            report.add("error", "C2", f"run_test 末项缺少 {desc}")


def _check_placeholders(report: FileReport, data: dict):
    """检查占位符"""
    raw = report.raw_text or ""

    # D1: 运行时占位符应保留
    for ph in RUNTIME_PLACEHOLDERS:
        if ph not in raw:
            # 在 assign_params 的 cmd 中查找
            found = False
            for ap in data.get("assign_params", []):
                if not isinstance(ap, dict):
                    continue
                for cmd_field in CMD_FIELDS:
                    for cmd_item in ap.get(cmd_field, []):
                        if isinstance(cmd_item, dict):
                            cmd_text = str(cmd_item.get("cmd", ""))
                            if ph in cmd_text:
                                found = True
                                break
            if not found:
                report.add("warning", "D1", f"未找到运行时占位符 {ph}, 可能已被误替换")

    # D2: 变量占位符应已替换（timestamp 除外）
    for ph in VARIABLE_PLACEHOLDERS:
        if ph == "{timestamp}":
            continue
        if ph in raw:
            report.add("warning", "D2", f"发现未替换的变量占位符 {ph}")

    # D3: 占位路径检测
    if "/path/" in raw:
        report.add("info", "D3", "检测到占位路径模式 '/path/', 建议确认实际路径")
    if "placeholder" in raw.lower():
        report.add("info", "D3", "检测到 'placeholder' 关键字, 建议确认实际值")


def _check_host_name_rules(report: FileReport, data: dict):
    """检查 host_name 规则"""
    hosts_list = data.get("hosts_list", [])
    is_remote = bool(hosts_list) and any(
        isinstance(h, dict) and h.get("ip", "")
        for h in hosts_list
    )

    # 收集 hosts_list 中的 name
    host_names = set()
    for h in hosts_list:
        if isinstance(h, dict):
            hn = h.get("name", "")
            if hn:
                host_names.add(hn)

    # 远程模式检查
    run_test = data.get("run_test", [])
    if run_test and is_remote:
        last_item = run_test[-1]
        if isinstance(last_item, dict):
            hn = last_item.get("host_name", [])
            if isinstance(hn, list) and hn:
                for name in hn:
                    if name and name not in host_names:
                        report.add("error", "E3",
                                   f"run_test 末项 host_name '{name}' 未在 hosts_list 中定义")
            elif not hn:
                report.add("warning", "E2",
                           "远程模式下 run_test 末项 host_name 为空, 建议指定压测主机")


# ── Param YAML 校验 ───────────────────────────────────────

REQUIRED_PARAM_FIELDS = ["name", "ptype", "upper", "lower", "suggestion",
                         "choices", "enable", "default", "version"]

VALID_PTYPES = {"immutable", "uniform_int", "uniform_float", "categorical"}


def validate_param_yaml(report: FileReport, data: dict):
    """校验 param YAML — 全部格式/结构检查"""
    if not isinstance(data, dict):
        report.add("error", "A1", "param YAML 顶级结构不是 map")
        return

    if not data:
        report.add("error", "A1", "param YAML 为空")
        return

    all_param_names = {}  # name -> group_name (用于跨组查重)

    for group_name, group_data in data.items():
        if not isinstance(group_data, dict):
            report.add("error", "A1", f"参数组 '{group_name}' 不是有效 map")
            continue

        params = group_data.get("params", [])
        if params is None:
            report.add("error", "A1", f"参数组 '{group_name}' 缺少 params 列表")
            continue

        tunable_count = 0
        group_param_names = set()

        for i, param in enumerate(params):
            if not isinstance(param, dict):
                report.add("error", "A2", f"[{group_name}] params[{i}] 不是有效 map")
                continue

            _validate_single_param(report, group_name, i, param,
                                    group_param_names, all_param_names)

            # 统计可调参数
            if param.get("enable") is True and param.get("ptype") != "immutable":
                tunable_count += 1

        # D2: 可调参数数量
        if tunable_count > 10:
            report.add("warning", "D2",
                       f"[{group_name}] 可调参数 {tunable_count} 个, 超过 10 个上限")

    # C4: 跨组参数名重复
    # 已在 _validate_single_param 中检查


def _validate_single_param(report: FileReport, group_name: str, idx: int,
                           param: dict, group_names: set, all_names: dict):
    """校验单个参数的全部字段"""
    prefix = f"[{group_name}] params[{idx}]"

    # A2: 字段完整性
    for f in REQUIRED_PARAM_FIELDS:
        if f not in param:
            report.add("error", "A2", f"{prefix} 缺少字段: {f}")

    name = param.get("name", "")
    ptype = param.get("ptype", "")
    upper = param.get("upper")
    lower = param.get("lower")
    suggestion = param.get("suggestion")
    choices = param.get("choices", [])
    enable = param.get("enable")
    version = param.get("version")
    default = param.get("default")

    # C4: 参数名重复（组内）
    if name:
        if name in group_names:
            report.add("error", "C4", f"{prefix} 参数名 '{name}' 在组内重复")
        group_names.add(name)

        # 跨组查重
        if name in all_names:
            report.add("warning", "C4",
                       f"{prefix} 参数名 '{name}' 在 '{all_names[name]}' 组中也存在")
        else:
            all_names[name] = group_name

    # B1: ptype 合法值
    if ptype and ptype not in VALID_PTYPES:
        report.add("error", "B1", f"{prefix} ptype '{ptype}' 不合法, 应为 {VALID_PTYPES}")
        return

    # C2: enable 布尔化
    if enable is not None and not isinstance(enable, bool):
        report.add("error", "C2",
                   f"{prefix} enable 应为布尔值, 实际为 {type(enable).__name__}: {enable}")

    # B2: immutable 规则
    if ptype == "immutable":
        if upper is not None and upper != 0:
            report.add("error", "B2", f"{prefix} immutable 参数 upper 应为 0, 实际为 {upper}")
        if lower is not None and lower != 0:
            report.add("error", "B2", f"{prefix} immutable 参数 lower 应为 0, 实际为 {lower}")
        if not choices or len(choices) == 0:
            report.add("error", "B2", f"{prefix} immutable 参数 choices 不应为空")
        elif len(choices) > 1:
            report.add("warning", "B2",
                       f"{prefix} immutable 参数 choices 有 {len(choices)} 个元素, 建议仅保留一个")
        if choices and suggestion is not None and suggestion != "" and suggestion != choices[0]:
            report.add("error", "B2",
                       f"{prefix} immutable 参数 suggestion='{suggestion}' 应等于 choices[0]='{choices[0]}'")

    # B3: uniform_int / uniform_float 规则
    elif ptype in ("uniform_int", "uniform_float"):
        if choices and len(choices) > 0:
            report.add("error", "B3", f"{prefix} {ptype} 参数 choices 应为空列表, 实际有 {len(choices)} 个元素")
        # lower <= upper
        if lower is not None and upper is not None:
            try:
                lower_val = float(lower) if lower != "" else None
                upper_val = float(upper) if upper != "" else None
                if lower_val is not None and upper_val is not None:
                    if lower_val > upper_val:
                        report.add("error", "B3",
                                   f"{prefix} lower={lower} > upper={upper}")
                # suggestion 在 [lower, upper] 范围内
                sugg_val = None
                if suggestion is not None and suggestion != "":
                    try:
                        sugg_val = float(suggestion)
                    except (ValueError, TypeError):
                        report.add("error", "B3",
                                   f"{prefix} suggestion='{suggestion}' 无法转为数值")
                if sugg_val is not None and lower_val is not None and upper_val is not None:
                    if sugg_val < lower_val or sugg_val > upper_val:
                        report.add("error", "B3",
                                   f"{prefix} suggestion={suggestion} 不在 [{lower}, {upper}] 范围内")
            except (ValueError, TypeError):
                report.add("error", "B3",
                           f"{prefix} 数值转换失败: lower={lower}, upper={upper}, suggestion={suggestion}")

    # B4: categorical 规则
    elif ptype == "categorical":
        if not choices or len(choices) < 2:
            report.add("error", "B4",
                       f"{prefix} categorical 参数 choices 应至少有 2 个元素, 实际 {len(choices) if choices else 0} 个")
        if suggestion is not None and suggestion != "" and choices:
            if suggestion not in choices:
                report.add("error", "B4",
                           f"{prefix} suggestion='{suggestion}' 不在 choices={choices} 中")

    # C1: suggestion 非空
    if suggestion is None or (isinstance(suggestion, str) and suggestion == ""):
        report.add("error", "C1", f"{prefix} suggestion 为空")

    # C3: version 格式
    if version is not None:
        if not isinstance(version, list):
            report.add("error", "C3",
                       f"{prefix} version 应为列表, 实际为 {type(version).__name__}")

    # D4: choices 元素类型（应为字符串）
    if choices and isinstance(choices, list):
        for j, c in enumerate(choices):
            if not isinstance(c, str) and not isinstance(c, (int, float)):
                report.add("warning", "D4",
                           f"{prefix} choices[{j}] 类型异常: {type(c).__name__}")


# ── 跨文件校验 ─────────────────────────────────────────────

def validate_cross_file(task_report: FileReport, param_report: FileReport,
                        task_data: dict, param_data: dict):
    """跨文件一致性校验（格式层面）"""
    assign_params = task_data.get("assign_params", [])

    task_group_names = set()
    task_enabled_groups = set()
    for ap in assign_params:
        if isinstance(ap, dict):
            name = ap.get("name", "")
            task_group_names.add(name)
            if ap.get("enable") is True:
                task_enabled_groups.add(name)

    param_group_names = set(param_data.keys()) if param_data else set()

    # X1: task 中有应用参数组但 param 中没有
    for name in task_group_names:
        if name not in ("System", "Kunpeng uarch") and name not in param_group_names:
            task_report.add("error", "X1",
                            f"task YAML 参数组 '{name}' 在 param YAML 中无对应定义")

    # X2: param 中有但 task 中没有
    for name in param_group_names:
        if name not in task_group_names:
            param_report.add("warning", "X2",
                             f"param YAML 参数组 '{name}' 在 task YAML assign_params 中无对应条目")

    # X2: enable=True 的组在 param 中有定义
    for name in task_enabled_groups:
        if name not in ("System", "Kunpeng uarch") and name not in param_group_names:
            task_report.add("warning", "X2",
                            f"task YAML enable=True 的参数组 '{name}' 在 param YAML 中无参数定义")

    # X3: System 参数组
    if "System" not in task_group_names:
        task_report.add("info", "X3",
                         "task YAML 中缺少 System 参数组条目（即使 enable=False 也建议保留）")


# ── 主流程 ─────────────────────────────────────────────────

def load_yaml(file_path: str) -> tuple[Optional[dict], Optional[str]]:
    """加载 YAML 文件"""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        return data, None
    except yaml.YAMLError as e:
        return None, str(e)
    except FileNotFoundError:
        return None, f"文件不存在: {file_path}"
    except Exception as e:
        return None, str(e)


def load_raw_text(file_path: str) -> str:
    """读取原始文件文本（用于格式检查）"""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""


def format_report_human(reports: list) -> str:
    """人类可读报告"""
    lines = []
    lines.append("=" * 60)
    lines.append("模板格式校验报告")
    lines.append("=" * 60)

    total_errors = 0
    total_warnings = 0
    total_infos = 0
    total_fixed = 0

    for report in reports:
        lines.append("")
        lines.append(f"[{report.file_type}] {report.file_path}")
        lines.append("-" * 60)

        if report.parse_error:
            lines.append(f"  [ERROR] YAML 解析失败: {report.parse_error}")
            total_errors += 1
            continue

        if not report.results:
            lines.append("  [PASS] 格式校验通过")
            continue

        for r in report.results:
            icon = {"error": "[ERROR]", "warning": "[WARN]", "info": "[INFO]"}.get(r.severity, "[?]")
            fixed_tag = " [已修复]" if r.auto_fixed else ""
            lines.append(f"  {icon} [{r.rule_id}] {r.message}{fixed_tag}")

            if r.severity == "error" and not r.auto_fixed:
                total_errors += 1
            elif r.severity == "warning":
                total_warnings += 1
            elif r.severity == "info":
                total_infos += 1
            if r.auto_fixed:
                total_fixed += 1

    # 跨文件
    cross_results = [r for rep in reports for r in rep.results if r.rule_id.startswith("X")]
    if len(reports) == 2 and all(r.parse_error is None for r in reports):
        lines.append("")
        lines.append("[cross] 跨文件一致性")
        lines.append("-" * 60)
        if not cross_results:
            lines.append("  [PASS] 跨文件一致性检查通过")
        else:
            for r in cross_results:
                icon = {"error": "[ERROR]", "warning": "[WARN]", "info": "[INFO]"}.get(r.severity, "[?]")
                lines.append(f"  {icon} [{r.rule_id}] {r.message}")

    lines.append("")
    lines.append("=" * 60)
    parts = []
    if total_errors:
        parts.append(f"{total_errors} 错误")
    if total_warnings:
        parts.append(f"{total_warnings} 警告")
    if total_infos:
        parts.append(f"{total_infos} 建议")
    if total_fixed:
        parts.append(f"{total_fixed} 已修复")

    if not parts:
        lines.append("[PASS] 全部格式校验通过")
    else:
        lines.append(f"汇总: {' / '.join(parts)}")
    lines.append("=" * 60)

    return "\n".join(lines)


def format_report_summary(reports: list) -> str:
    """紧凑输出（供 agent 快速解析）"""
    lines = []
    for report in reports:
        if report.parse_error:
            lines.append(f"PARSE_ERROR|{report.file_type}|{report.parse_error}")
            continue

        for r in report.results:
            lines.append(f"{r.severity}|{r.rule_id}|{r.file_type}|{r.message}")

    cross_results = [r for rep in reports for r in rep.results if r.rule_id.startswith("X")]
    for r in cross_results:
        lines.append(f"{r.severity}|{r.rule_id}|cross|{r.message}")

    errors = sum(1 for l in lines if l.startswith("error|"))
    warnings = sum(1 for l in lines if l.startswith("warning|"))
    infos = sum(1 for l in lines if l.startswith("info|"))

    lines.append(f"SUMMARY|errors={errors}|warnings={warnings}|infos={infos}")

    return "\n".join(lines)


def format_report_json(reports: list) -> str:
    """JSON 输出"""
    output = {
        "files": [],
        "summary": {"errors": 0, "warnings": 0, "infos": 0, "fixed": 0}
    }

    for report in reports:
        file_data = {
            "path": report.file_path,
            "type": report.file_type,
            "parse_error": report.parse_error,
            "results": []
        }
        for r in report.results:
            file_data["results"].append({
                "severity": r.severity,
                "rule_id": r.rule_id,
                "message": r.message,
                "auto_fixed": r.auto_fixed
            })
            if r.severity == "error" and not r.auto_fixed:
                output["summary"]["errors"] += 1
            elif r.severity == "warning":
                output["summary"]["warnings"] += 1
            elif r.severity == "info":
                output["summary"]["infos"] += 1
            if r.auto_fixed:
                output["summary"]["fixed"] += 1

        output["files"].append(file_data)

    return json.dumps(output, ensure_ascii=False, indent=2)


def main():
    parser = argparse.ArgumentParser(description="模板格式校验脚本")
    parser.add_argument("task", nargs="?", help="task YAML 文件路径")
    parser.add_argument("param", nargs="?", help="param YAML 文件路径")
    parser.add_argument("--task", dest="task_opt", help="task YAML 文件路径")
    parser.add_argument("--param", dest="param_opt", help="param YAML 文件路径")
    parser.add_argument("--summary", action="store_true", help="紧凑输出（供 agent 解析）")
    parser.add_argument("--json", action="store_true", help="JSON 输出")
    args = parser.parse_args()

    task_path = args.task_opt or args.task
    param_path = args.param_opt or args.param

    if not task_path and not param_path:
        parser.print_help()
        sys.exit(1)

    reports = []

    # 校验 task YAML
    if task_path:
        if not os.path.exists(task_path):
            print(f"[ERROR] 文件不存在: {task_path}")
            sys.exit(1)

        report = FileReport(file_path=task_path, file_type="task")
        report.raw_text = load_raw_text(task_path)
        data, error = load_yaml(task_path)

        if error:
            report.parse_error = error
        elif data is not None:
            validate_task_yaml(report, data)

        reports.append(report)

    # 校验 param YAML
    if param_path:
        if not os.path.exists(param_path):
            print(f"[ERROR] 文件不存在: {param_path}")
            sys.exit(1)

        report = FileReport(file_path=param_path, file_type="param")
        report.raw_text = load_raw_text(param_path)
        data, error = load_yaml(param_path)

        if error:
            report.parse_error = error
        elif data is not None:
            validate_param_yaml(report, data)

        reports.append(report)

    # 跨文件校验
    if len(reports) == 2 and all(r.parse_error is None for r in reports):
        task_data, _ = load_yaml(reports[0].file_path)
        param_data, _ = load_yaml(reports[1].file_path)
        if task_data and param_data:
            validate_cross_file(reports[0], reports[1], task_data, param_data)

    # 输出
    if args.json:
        print(format_report_json(reports))
    elif args.summary:
        print(format_report_summary(reports))
    else:
        print(format_report_human(reports))

    # 返回码
    has_error = any(r.error_count > 0 for r in reports)
    has_warning = any(r.warning_count > 0 for r in reports)

    if has_error:
        sys.exit(1)
    elif has_warning:
        sys.exit(2)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()

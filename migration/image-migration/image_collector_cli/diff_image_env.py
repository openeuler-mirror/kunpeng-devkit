#!/usr/bin/env python3
# =============================================================================
# diff_image_env.py
#
# 功能:
#   读取 swe_image_analysis_table.xlsx，对"是否为基础镜像"为"否"的每个镜像，
#   找到其对应的基础镜像 JSON，从当前镜像 JSON 中删除基础镜像中已有的相同内容，
#   保持原始 JSON 结构不变，只保留相比基础镜像新增/变化的部分。
#   并在顶层添加以下元数据字段:
#     - language_type  (语言类型)
#     - github_url     (GitHub URL)
#     - base_image     (基础镜像名称)
#
# 输入:
#   XLSX_FILE       : xlsx 表格路径
#   JSON_INPUT_DIR  : 环境采集 JSON 所在目录 (env_inspect_out/images)
#   OUTPUT_DIR      : 输出目录 (在当前项目下, 按语言分层)
#
# 输出文件结构:
#   <OUTPUT_DIR>/
#     <语言>/
#       <镜像名>.json
#
# 用法:
#   python3 diff_image_env.py [XLSX_FILE] [JSON_INPUT_DIR] [OUTPUT_DIR]
#
# 环境变量:
#   REGISTRY_PREFIX  内网仓库前缀（默认: registry.example.com/custom_prod/）
#
# 依赖: openpyxl
# =============================================================================

import sys
import copy
import json
import re
from pathlib import Path

# --------------------------------------------------------------------------
# 依赖检查
# --------------------------------------------------------------------------
try:
    import openpyxl
except ImportError:
    print("[ERROR] 缺少依赖 openpyxl，请先安装: pip3 install openpyxl", file=sys.stderr)
    sys.exit(1)

# --------------------------------------------------------------------------
# 参数
# --------------------------------------------------------------------------
import os

SCRIPT_DIR = Path(__file__).parent.resolve()

XLSX_FILE      = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("./image_analysis_table.xlsx")
JSON_INPUT_DIR = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("./env_inspect_out/images")
OUTPUT_DIR     = Path(sys.argv[3]) if len(sys.argv) > 3 else SCRIPT_DIR / "diff_env_out"
REGISTRY_PREFIX_ENV = os.environ.get("REGISTRY_PREFIX", "registry.example.com/custom_prod/")

# --------------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------------

def image_name_to_filename(image_name):
    """将镜像名称转换为 JSON 文件名：/ → _，: → _，末尾加 .json"""
    return image_name.replace("/", "_").replace(":", "_") + ".json"


def load_json_file(path):
    if not path.exists():
        print(f"  [WARN] JSON 文件不存在: {path}", file=sys.stderr)
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"  [WARN] JSON 加载失败 {path}: {e}", file=sys.stderr)
        return None


def sanitize_lang_dirname(lang):
    name = re.sub(r'[/\\]', '_', lang.strip())
    name = re.sub(r'[<>:"|?*]', '', name)
    return name or "Unknown"


# --------------------------------------------------------------------------
# 核心：从当前 JSON 中"减去"基础镜像已有的内容，保持结构不变
# --------------------------------------------------------------------------

def pkg_name(item):
    """从 'name=version' 或 'name:arch=version' 中提取包名"""
    return item.split("=")[0].split(":")[0].strip() if item else item


def subtract_list(curr_list, base_list):
    """
    从 curr_list 中删除 base_list 中已有的包（按包名匹配，忽略版本）。
    返回: 仅保留 curr_list 中新增的、或版本升级的条目。
    """
    base_names = {pkg_name(x): x for x in base_list}
    result = []
    for item in curr_list:
        name = pkg_name(item)
        if name not in base_names:
            # 基础镜像没有，完全新增，保留
            result.append(item)
        elif item != base_names[name]:
            # 版本不同（升级），保留
            result.append(item)
        # else: 完全相同，删除
    return result


def subtract_dict(curr_dict, base_dict):
    """
    从 curr_dict 中删除 base_dict 中已有且值相同的 key。
    值不同的 key 保留（保持 current 的值）。
    返回: 只含新增或值变化的 key-value。
    """
    result = {}
    for k, v in curr_dict.items():
        if k not in base_dict:
            result[k] = v          # 新增的 key，保留
        elif v != base_dict[k]:
            result[k] = v          # 值有变化，保留 current 的值
        # else: 完全相同，删除
    return result


def subtract_section(curr_sec, base_sec):
    """
    递归地从 curr_sec 中减去 base_sec 中已有的相同内容。
    - dict: 递归处理每个字段
    - list: 用 subtract_list（包名匹配）
    - 标量: 相同则置为 None（调用方负责删除 None 字段）
    """
    if curr_sec is None:
        return None

    if isinstance(curr_sec, dict) and isinstance(base_sec, dict):
        result = {}
        for k, v in curr_sec.items():
            base_v = base_sec.get(k)
            if base_v is None:
                # 基础镜像没有此字段，完整保留
                result[k] = v
            elif isinstance(v, list) and isinstance(base_v, list):
                remaining = subtract_list(v, base_v)
                result[k] = remaining   # 即使为空列表也保留 key（保持结构）
            elif isinstance(v, dict) and isinstance(base_v, dict):
                result[k] = subtract_section(v, base_v)
            else:
                if v != base_v:
                    result[k] = v       # 值变化，保留
                # else: 相同，删除（不写入 result）
        return result

    if isinstance(curr_sec, list) and isinstance(base_sec, list):
        return subtract_list(curr_sec, base_sec)

    # 标量
    if curr_sec == base_sec:
        return None   # 相同，信号：调用方可选择删除
    return curr_sec


def subtract_json(curr_json, base_json, language, github_url, base_image_name):
    """
    从 curr_json 中减去 base_json 中已有的相同内容，
    保持原始结构，在顶层注入元数据。
    """
    result = {}

    # ---- 顶层注入元数据 ----
    result["diff_meta"] = {
        "language_type": language,
        "github_url": github_url,
        "base_image": base_image_name,
        "current_image": curr_json.get("meta", {}).get("source_image", ""),
        "current_size_bytes": curr_json.get("meta", {}).get("image_size_bytes"),
        "base_size_bytes": base_json.get("meta", {}).get("image_size_bytes"),
    }

    # ---- meta 节：保留当前镜像的 meta，补充 size_increase ----
    curr_meta = curr_json.get("meta", {})
    base_meta = base_json.get("meta", {})
    meta_out = dict(curr_meta)
    curr_sz = curr_meta.get("image_size_bytes") or 0
    base_sz = base_meta.get("image_size_bytes") or 0
    if curr_sz and base_sz:
        meta_out["size_increase_bytes"] = curr_sz - base_sz
        meta_out["size_increase_mb"] = round((curr_sz - base_sz) / 1024 / 1024, 1)
    result["meta"] = meta_out

    # ---- image_env 节：删除 base 中相同的环境变量 ----
    curr_env = curr_json.get("image_env", {})
    base_env = base_json.get("image_env", {})
    result["image_env"] = subtract_dict(curr_env, base_env)

    # ---- os 节：相同则标记，不同则保留 current 的值 ----
    curr_os = curr_json.get("os", {})
    base_os = base_json.get("os", {})
    os_out = subtract_dict(curr_os, base_os)
    if not os_out:
        result["os"] = {"_same_as_base": True}
    else:
        result["os"] = os_out

    # ---- packages 节：删除 base 中已有的包，只保留新增/升级 ----
    curr_pkg = curr_json.get("packages", {})
    base_pkg = base_json.get("packages", {})
    if curr_pkg:
        curr_list = curr_pkg.get("list", [])
        base_list = base_pkg.get("list", [])
        remaining = subtract_list(curr_list, base_list)
        result["packages"] = {
            "manager": curr_pkg.get("manager", ""),
            "count_base": len(base_list),
            "count_current": len(curr_list),
            "count_new": len(remaining),
            "list": remaining,
        }

    # ---- 其他所有节（语言节）：递归减去 ----
    skip = {"meta", "image_env", "os", "packages"}
    for sec_name in curr_json:
        if sec_name in skip:
            continue
        curr_sec = curr_json[sec_name]
        base_sec = base_json.get(sec_name)

        if base_sec is None:
            # 基础镜像没有此节，完整保留
            result[sec_name] = curr_sec
        else:
            result[sec_name] = subtract_section(curr_sec, base_sec)

    return result


# --------------------------------------------------------------------------
# 读取 XLSX
# --------------------------------------------------------------------------

def load_xlsx(xlsx_path):
    print(f"[INFO] 读取 xlsx: {xlsx_path}", file=sys.stderr)
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb.active
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        print("[ERROR] xlsx 为空", file=sys.stderr)
        sys.exit(1)

    header = [str(h).strip() if h else "" for h in rows[0]]
    print(f"[INFO] 表头: {header}", file=sys.stderr)
    col_idx = {name: i for i, name in enumerate(header)}

    def get_col(row, *names):
        for name in names:
            if name in col_idx:
                val = row[col_idx[name]]
                return str(val).strip() if val is not None else ""
        return ""

    base_images, non_base_images = [], []
    for row in rows[1:]:
        if all(v is None for v in row):
            continue
        is_base    = get_col(row, "是否为基础镜像")
        container  = get_col(row, "容器名称")
        base_img   = get_col(row, "基础镜像")
        language   = get_col(row, "语言类型")
        orig_image = get_col(row, "原版镜像名称")
        github_url = get_col(row, "GitHub URL")
        note       = get_col(row, "备注")
        record = {
            "is_base": is_base, "container_name": container,
            "base_image": base_img, "language": language,
            "original_image": orig_image, "github_url": github_url, "note": note,
        }
        if is_base == "是":
            base_images.append(record)
        elif is_base == "否":
            non_base_images.append(record)

    wb.close()
    print(f"[INFO] 基础镜像: {len(base_images)} 条，非基础镜像: {len(non_base_images)} 条", file=sys.stderr)
    return base_images, non_base_images


def build_base_json_index(base_records, json_dir):
    index = {}
    for rec in base_records:
        orig_image = rec["original_image"]
        container  = rec["container_name"]
        if not orig_image:
            continue
        fname = image_name_to_filename(orig_image)
        data  = load_json_file(json_dir / fname)
        if data is None:
            continue
        if container:
            index[container] = data
        index[orig_image] = data
    return index


def find_base_json(base_image_col, base_index, json_dir):
    if not base_image_col:
        return None
    if base_image_col in base_index:
        return base_index[base_image_col]
    full_name = REGISTRY_PREFIX_ENV + base_image_col
    if full_name in base_index:
        return base_index[full_name]
    for name in (base_image_col, full_name):
        fpath = json_dir / image_name_to_filename(name)
        if fpath.exists():
            return load_json_file(fpath)
    return None


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------

def main():
    print(f"[INFO] XLSX:           {XLSX_FILE}", file=sys.stderr)
    print(f"[INFO] JSON 输入目录:  {JSON_INPUT_DIR}", file=sys.stderr)
    print(f"[INFO] 输出目录:       {OUTPUT_DIR}", file=sys.stderr)
    print(f"[INFO] 仓库前缀:       {REGISTRY_PREFIX_ENV}", file=sys.stderr)

    if not XLSX_FILE.exists():
        print(f"[ERROR] xlsx 文件不存在: {XLSX_FILE}", file=sys.stderr)
        sys.exit(1)
    if not JSON_INPUT_DIR.exists():
        print(f"[ERROR] JSON 输入目录不存在: {JSON_INPUT_DIR}", file=sys.stderr)
        sys.exit(1)

    base_records, non_base_records = load_xlsx(XLSX_FILE)

    print(f"\n[INFO] 构建基础镜像索引...", file=sys.stderr)
    base_index = build_base_json_index(base_records, JSON_INPUT_DIR)
    print(f"[INFO] 索引中共 {len(base_index)} 个基础镜像条目", file=sys.stderr)

    stats = {"total": len(non_base_records), "success": 0,
             "missing_json": 0, "missing_base": 0, "error": 0}

    print(f"\n[INFO] 开始处理 {stats['total']} 个非基础镜像...\n", file=sys.stderr)

    for rec in non_base_records:
        orig_image = rec["original_image"]
        base_img   = rec["base_image"]
        language   = rec["language"]
        github_url = rec["github_url"]
        container  = rec["container_name"]

        if not orig_image:
            print(f"  [SKIP] 原版镜像名为空，container={container}", file=sys.stderr)
            continue

        print(f"  [PROC] {container} (lang={language}, base={base_img})", file=sys.stderr)

        curr_fname = image_name_to_filename(orig_image)
        curr_json  = load_json_file(JSON_INPUT_DIR / curr_fname)
        if curr_json is None:
            print(f"         → [SKIP] 当前镜像 JSON 不存在: {curr_fname}", file=sys.stderr)
            stats["missing_json"] += 1
            continue

        base_json = find_base_json(base_img, base_index, JSON_INPUT_DIR)
        if base_json is None:
            print(f"         → [WARN] 基础镜像 JSON 未找到: {base_img}，将输出当前镜像全量", file=sys.stderr)
            stats["missing_base"] += 1
            output_data = curr_json
            # 注入元数据到顶层
            output_data = dict(curr_json)
            output_data["diff_meta"] = {
                "language_type": language,
                "github_url": github_url,
                "base_image": base_img,
                "base_image_json_found": False,
                "note": "base image JSON not found; full current image data included",
            }
        else:
            try:
                output_data = subtract_json(curr_json, base_json, language, github_url, base_img)
                stats["success"] += 1
            except Exception as e:
                import traceback
                print(f"         → [ERROR] 处理失败: {e}", file=sys.stderr)
                traceback.print_exc(file=sys.stderr)
                stats["error"] += 1
                output_data = dict(curr_json)
                output_data["diff_meta"] = {
                    "language_type": language,
                    "github_url": github_url,
                    "base_image": base_img,
                    "error": str(e),
                }

        lang_dir_name = sanitize_lang_dirname(language) if language else "Unknown"
        out_lang_dir  = OUTPUT_DIR / lang_dir_name
        out_lang_dir.mkdir(parents=True, exist_ok=True)

        out_fpath = out_lang_dir / curr_fname
        with open(out_fpath, "w", encoding="utf-8") as f:
            json.dump(output_data, f, ensure_ascii=False, indent=2)

        print(f"         → 输出: {out_lang_dir.name}/{curr_fname}", file=sys.stderr)

    print("\n" + "=" * 60, file=sys.stderr)
    print("统计摘要:", file=sys.stderr)
    print(f"  总计非基础镜像:   {stats['total']}", file=sys.stderr)
    print(f"  成功 diff:        {stats['success']}", file=sys.stderr)
    print(f"  缺少当前 JSON:    {stats['missing_json']}", file=sys.stderr)
    print(f"  缺少基础镜像JSON: {stats['missing_base']}", file=sys.stderr)
    print(f"  diff 计算出错:    {stats['error']}", file=sys.stderr)
    print(f"  输出目录:         {OUTPUT_DIR}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(f"[DONE] 输出已写入: {OUTPUT_DIR}", file=sys.stderr)


if __name__ == "__main__":
    main()

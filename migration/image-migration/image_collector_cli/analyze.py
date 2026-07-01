#!/usr/bin/env python3
# =============================================================================
# analyze.py  —  采集结果分析
#
# 两种 mode：
#   base  ：建立基础镜像索引（从 manifest.json 提取 sha256 / layers），
#           在 collect-dir 下写 _base_index.json
#   biz   ：读取业务镜像的三份采集结果，与基础镜像做 diff，
#           为每个镜像写 diff.json（覆盖 layer 字段的差异部分）
# =============================================================================

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


# ═══════════════════════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════════════════════

def _safe(image: str) -> str:
    return image.replace("/", "_").replace(":", "_").replace(" ", "_")


def _load(p: Path) -> dict[str, Any] | None:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"  [WARN] 读取失败 {p}: {e}", file=sys.stderr)
        return None


def _pkg_name(item: str) -> str:
    return item.split("=", 1)[0].split(":", 1)[0].strip()


# ═══════════════════════════════════════════════════════════════════════════
# 包/列表差集
# ═══════════════════════════════════════════════════════════════════════════

def _subtract_pkg_list(curr: list, base: list) -> list:
    base_by_name = {_pkg_name(str(x)): str(x) for x in base}
    result = []
    for item in curr:
        name = _pkg_name(str(item))
        if name not in base_by_name or base_by_name[name] != str(item):
            result.append(item)
    return result


def _subtract_dict(curr: dict, base: dict) -> dict:
    return {k: v for k, v in curr.items() if k not in base or base[k] != v}


def _subtract_section(curr: Any, base: Any) -> Any:
    if curr is None:
        return None
    if isinstance(curr, dict) and isinstance(base, dict):
        result: dict = {}
        for k, v in curr.items():
            bv = base.get(k)
            if bv is None:
                result[k] = v
            elif isinstance(v, list) and isinstance(bv, list):
                result[k] = _subtract_pkg_list(v, bv)
            elif isinstance(v, dict) and isinstance(bv, dict):
                result[k] = _subtract_section(v, bv)
            elif v != bv:
                result[k] = v
        return result
    if isinstance(curr, list) and isinstance(base, list):
        return _subtract_pkg_list(curr, base)
    return None if curr == base else curr


# ═══════════════════════════════════════════════════════════════════════════
# 语言推断
# ═══════════════════════════════════════════════════════════════════════════

_LANG_MAP = {
    "nodejs": "Node.js", "go": "Go", "python": "Python",
    "java": "Java", "php": "PHP", "ruby": "Ruby",
    "rust": "Rust", "c_cpp": "C++", ".net": ".NET",
}

def _infer_language(layer: dict) -> str:
    detected = [label for key, label in _LANG_MAP.items()
                if isinstance(layer.get(key), dict) and any(bool(v) for v in layer[key].values())]
    if not detected:
        return "Unknown"
    return detected[0] if len(detected) == 1 else "Mixed"


# ═══════════════════════════════════════════════════════════════════════════
# 基础镜像匹配分数
# ═══════════════════════════════════════════════════════════════════════════

def _score(biz_layer: dict, base_layer: dict) -> float:
    bp = {_pkg_name(str(x)) for x in biz_layer.get("packages", {}).get("list", [])}
    basep = {_pkg_name(str(x)) for x in base_layer.get("packages", {}).get("list", [])}
    if bp and basep:
        union = len(bp | basep)
        score = len(bp & basep) / union if union else 0.0
    else:
        score = 0.0
    if (biz_layer.get("os", {}).get("id", "") ==
            base_layer.get("os", {}).get("id", "") != ""):
        score = min(1.0, score + 0.1)
    return score


# ═══════════════════════════════════════════════════════════════════════════
# 基础镜像索引中的 sha256 / layers 提取（来自 manifest.json）
# ═══════════════════════════════════════════════════════════════════════════

def _extract_base_manifest_info(manifest: dict) -> dict:
    """从 manifest.json 提取 sha256 id、rootfs layers、digest 信息。"""
    return {
        "id":           manifest.get("id", ""),
        "repo_digests": manifest.get("repo_digests", []),
        "rootfs_layers": manifest.get("rootfs", {}).get("layers", []),
        "architecture": manifest.get("architecture", ""),
        "os":           manifest.get("os", ""),
        "size":         manifest.get("size", 0),
    }


# ═══════════════════════════════════════════════════════════════════════════
# MODE: base  —  建立基础镜像索引
# ═══════════════════════════════════════════════════════════════════════════

def run_base(collect_dir: Path) -> None:
    """扫描 collect_dir 下所有镜像子目录，建立 _base_index.json。"""
    index: dict[str, Any] = {}
    count = 0

    for img_dir in sorted(collect_dir.iterdir()):
        if not img_dir.is_dir() or img_dir.name.startswith("_"):
            continue

        manifest = _load(img_dir / "manifest.json")
        layer    = _load(img_dir / "layer.json")
        history  = _load(img_dir / "history.json")

        # 从 manifest 取镜像真实名称
        image_name = ""
        if manifest:
            tags = manifest.get("repo_tags", [])
            image_name = tags[0] if tags else manifest.get("meta", {}).get("source_image", "")
        if not image_name:
            status = _load(img_dir / "_status.json")
            image_name = (status or {}).get("image", img_dir.name)

        entry: dict[str, Any] = {
            "dir":        img_dir.name,
            "image_name": image_name,
        }
        if manifest:
            entry["manifest_info"] = _extract_base_manifest_info(manifest)
        if layer:
            entry["layer_summary"] = {
                "packages_count": len(layer.get("packages", {}).get("list", [])),
                "os":             layer.get("os", {}),
                "image_env":      layer.get("image_env", {}),
                "_layer_data":    layer,   # 完整数据供 diff 使用
            }
        if history:
            entry["history_layer_count"] = history.get("meta", {}).get("layer_count", 0)

        index[image_name] = entry
        count += 1
        print(f"  [base-index] {image_name}", file=sys.stderr)

    out_path = collect_dir / "_base_index.json"
    out_path.write_text(json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[base] 索引完成: {count} 个基础镜像 → {out_path}", file=sys.stderr)


# ═══════════════════════════════════════════════════════════════════════════
# MODE: biz  —  读取业务镜像，做 diff，写 diff.json
# ═══════════════════════════════════════════════════════════════════════════

def _find_best_base(biz_layer: dict,
                    base_index: dict[str, Any]) -> tuple[str, dict | None, float]:
    """找最佳基础镜像，返回 (name, layer_data, confidence)。"""
    best_name = ""
    best_data = None
    best_score = -1.0

    for name, entry in base_index.items():
        base_layer_data = entry.get("layer_summary", {}).get("_layer_data")
        if not base_layer_data:
            continue
        s = _score(biz_layer, base_layer_data)
        if s > best_score:
            best_score = s
            best_name  = name
            best_data  = base_layer_data

    return best_name, best_data, best_score


def _build_diff(biz_layer: dict, base_layer: dict,
                base_name: str, confidence: float,
                base_manifest_info: dict) -> dict:
    """构建 diff.json 内容，覆盖 layer 的差异部分。"""
    language = _infer_language(biz_layer)
    biz_meta = biz_layer.get("meta", {})
    source   = biz_layer.get("source_code", {})

    biz_pkgs  = biz_layer.get("packages", {}).get("list", [])
    base_pkgs = base_layer.get("packages", {}).get("list", [])
    new_pkgs  = _subtract_pkg_list(biz_pkgs, base_pkgs)

    diff: dict[str, Any] = {
        "diff_meta": {
            "language":              language,
            "current_image":         str(biz_meta.get("source_image", "")),
            "base_image":            base_name,
            "base_match_confidence": round(confidence, 6),
            # sha256 / digest / layers 来自基础镜像的 manifest
            "base_id":               base_manifest_info.get("id", ""),
            "base_repo_digests":     base_manifest_info.get("repo_digests", []),
            "base_rootfs_layers":    base_manifest_info.get("rootfs_layers", []),
            "base_architecture":     base_manifest_info.get("architecture", ""),
            "base_size_bytes":       base_manifest_info.get("size", 0),
            "current_size_bytes":    biz_meta.get("image_size_bytes", 0),
        },
        "source_code": source,
        # 只保留与基础镜像不同的环境变量
        "image_env_diff": _subtract_dict(
            biz_layer.get("image_env", {}),
            base_layer.get("image_env", {}),
        ),
        # OS 差异
        "os_diff": _subtract_dict(
            biz_layer.get("os", {}),
            base_layer.get("os", {}),
        ),
        # 包差异
        "packages_diff": {
            "manager":       biz_layer.get("packages", {}).get("manager", ""),
            "count_base":    len(base_pkgs),
            "count_current": len(biz_pkgs),
            "count_new":     len(new_pkgs),
            "list":          new_pkgs,
        },
    }

    # 其余语言节的差集（nodejs/go/python 等）
    skip = {"meta", "image_env", "os", "packages", "source_code"}
    for sec in biz_layer:
        if sec in skip:
            continue
        biz_sec  = biz_layer[sec]
        base_sec = base_layer.get(sec)
        if base_sec is None:
            diff[sec] = biz_sec
        else:
            val = _subtract_section(biz_sec, base_sec)
            if val:
                diff[sec] = val

    return diff


def run_biz(collect_dir: Path, base_dir: Path | None) -> None:
    """处理业务镜像：如有基础镜像索引则做 diff，写 diff.json。"""

    # 尝试加载基础镜像索引
    base_index: dict[str, Any] = {}
    if base_dir:
        idx_file = base_dir / "_base_index.json"
        if idx_file.exists():
            try:
                base_index = json.loads(idx_file.read_text(encoding="utf-8"))
                print(f"[biz] 加载基础镜像索引: {len(base_index)} 条", file=sys.stderr)
            except Exception as e:
                print(f"[biz] 基础镜像索引读取失败: {e}", file=sys.stderr)
        else:
            print(f"[biz] 未找到 _base_index.json in {base_dir}，跳过 diff", file=sys.stderr)
    else:
        print("[biz] 未指定 --base-dir，跳过 diff 分析", file=sys.stderr)

    diff_count = 0
    skip_count = 0

    for img_dir in sorted(collect_dir.iterdir()):
        if not img_dir.is_dir() or img_dir.name.startswith("_"):
            continue

        layer    = _load(img_dir / "layer.json")
        manifest = _load(img_dir / "manifest.json")
        status   = _load(img_dir / "_status.json") or {}
        image_name = status.get("image", img_dir.name)

        if not layer:
            print(f"  [biz] {image_name}: 无 layer.json，跳过 diff", file=sys.stderr)
            skip_count += 1
            continue

        if not base_index:
            skip_count += 1
            continue

        # 匹配最佳基础镜像
        best_name, best_layer, confidence = _find_best_base(layer, base_index)
        if not best_name or best_layer is None:
            print(f"  [biz] {image_name}: 无法匹配基础镜像，跳过 diff", file=sys.stderr)
            skip_count += 1
            continue

        # 获取基础镜像 manifest 信息（sha256 / layers）
        base_entry        = base_index[best_name]
        base_manifest_raw = base_entry.get("manifest_info", {})

        diff = _build_diff(layer, best_layer, best_name, confidence, base_manifest_raw)

        out_path = img_dir / "diff.json"
        out_path.write_text(json.dumps(diff, ensure_ascii=False, indent=2), encoding="utf-8")
        diff_count += 1
        print(f"  [biz] {image_name} → base={best_name}  conf={confidence:.3f}  "
              f"new_pkgs={diff['packages_diff']['count_new']}  diff → {out_path.name}",
              file=sys.stderr)

    print(f"[biz] diff 完成: {diff_count} 个，跳过: {skip_count} 个", file=sys.stderr)


# ═══════════════════════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════════════════════

def main() -> None:
    parser = argparse.ArgumentParser(description="Image collection analyzer")
    parser.add_argument("--mode",        required=True, choices=["base", "biz"])
    parser.add_argument("--collect-dir", required=True, type=Path,
                        help="collect.sh 的输出目录（含各镜像子目录）")
    parser.add_argument("--base-dir",    type=Path, default=None,
                        help="[biz 模式] 基础镜像的 collect-dir（含 _base_index.json）")
    args = parser.parse_args()

    if not args.collect_dir.exists():
        print(f"[ERR] collect-dir 不存在: {args.collect_dir}", file=sys.stderr)
        sys.exit(1)

    if args.mode == "base":
        run_base(args.collect_dir)
    else:
        run_biz(args.collect_dir, args.base_dir)


if __name__ == "__main__":
    main()

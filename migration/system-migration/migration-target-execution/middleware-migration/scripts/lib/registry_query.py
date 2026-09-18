#!/usr/bin/env python3
"""
Registry 查询工具 - 基于 python3 标准库 json 解析 config/middleware_registry.json

用法:
  python3 registry_query.py [-e] '<path>' [file]

路径语法:
  .strategies.openjdk.install_dir              # 点分
  .strategies."openjdk".install_dir            # 带引号（数字键或特殊字符）
  .strategies."openjdk".dependencies[0].type   # 数组索引
  .strategies."openjdk".dependencies | length  # 取长度

选项:
  -e   存在性检查（值为 None 时返回退出码 1，其余返回 0；False/0/空串/空集合均视为存在）
  不支持 select/管道过滤等复杂表达式（这类逻辑请在调用方用内联 python 实现）
"""
import json
import sys
import re
from pathlib import Path


# scripts/lib/registry_query.py → 模块根 = scripts/lib 上两级（middleware-migration/）
LIB_DIR = Path(__file__).resolve().parent
MW_ROOT = LIB_DIR.parent.parent
REGISTRY_FILE = MW_ROOT / "config" / "middleware_registry.json"


def parse_path(key):
    """把路径解析为 (token 列表, 是否取长度)"""
    key = key.strip()
    take_length = False
    if key.endswith('| length'):
        key = key[:-len('| length')].strip()
        take_length = True
    elif key.endswith('|length'):
        key = key[:-len('|length')].strip()
        take_length = True

    tokens = []
    k = key.lstrip('.')
    i = 0
    while i < len(k):
        c = k[i]
        if c == '.':
            i += 1
        elif c == '"':
            j = k.index('"', i + 1)
            tokens.append(('key', k[i + 1:j]))
            i = j + 1
        elif c == '[':
            j = k.index(']', i)
            tokens.append(('idx', int(k[i + 1:j])))
            i = j + 1
        else:
            m = re.match(r'[^.\[]+', k[i:])
            if m:
                tokens.append(('key', m.group()))
                i += len(m.group())
            else:
                i += 1
    return tokens, take_length


def lookup(data, tokens):
    cur = data
    for kind, val in tokens:
        if cur is None:
            return None
        try:
            if kind == 'key':
                if isinstance(cur, dict):
                    cur = cur.get(val)
                else:
                    return None
            elif kind == 'idx':
                if isinstance(cur, list) and 0 <= val < len(cur):
                    cur = cur[val]
                else:
                    return None
        except (KeyError, IndexError, TypeError):
            return None
    return cur


def main():
    args = sys.argv[1:]
    exists = False
    while args and args[0].startswith('-') and args[0] != '-':
        if args[0] == '-e':
            exists = True
            args = args[1:]
        else:
            break

    if not args:
        sys.stderr.write("用法: registry_query.py [-e] '<path>' [file]\n")
        sys.exit(2)

    key = args[0]
    path = args[1] if len(args) > 1 else str(REGISTRY_FILE)

    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        sys.stderr.write("加载 JSON 错误: {}\n".format(e))
        sys.exit(1)

    tokens, take_length = parse_path(key)
    value = lookup(data, tokens)

    if take_length:
        if isinstance(value, (list, dict, str)):
            value = len(value)
        else:
            value = 0

    if exists:
        sys.exit(1 if value is None else 0)

    if value is None:
        return
    if value is True:
        print('true')
    elif value is False:
        print('false')
    elif isinstance(value, (list, dict)):
        print(json.dumps(value, ensure_ascii=False))
    else:
        print(value)


if __name__ == '__main__':
    main()

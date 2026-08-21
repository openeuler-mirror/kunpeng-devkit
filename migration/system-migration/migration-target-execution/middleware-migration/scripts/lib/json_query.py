#!/usr/bin/env python3
"""
JSON 查询工具 - 替代 jq 的常用功能

用法:
  python3 json_query.py [-r] [-e] [-c] '<expr>' [file]
  echo '<json>' | python3 json_query.py [-r] [-e] [-c] '<expr>'

表达式: Python 表达式，d 代表根 JSON 数据
  d['key']                         # 取字段
  d[0]                             # 取数组元素
  len(d)                           # 数组长度
  d.get('key', '')                 # 安全取字段
  [x['type'] for x in d]           # 遍历数组取字段
  d.get('key') is not None         # 存在性检查

选项:
  -r   原始输出（字符串不加引号；列表逐元素输出）
  -e   存在性检查（结果为 None/False/空 时返回退出码 1）
  -c   紧凑 JSON 输出
"""
import json
import sys


def load_data(file_path=None):
    """从文件或 stdin 加载 JSON，空输入返回 None"""
    if file_path:
        with open(file_path, 'r', encoding='utf-8-sig') as f:
            return json.load(f)
    raw = sys.stdin.read().strip()
    if not raw:
        return None
    return json.loads(raw)


def main():
    args = sys.argv[1:]
    raw = False
    exists = False
    compact = False

    # 解析选项
    while args and args[0].startswith('-') and args[0] != '-':
        if args[0] == '-r':
            raw = True
        elif args[0] == '-e':
            exists = True
        elif args[0] == '-c':
            compact = True
        elif args[0] == '--':
            args = args[1:]
            break
        else:
            break
        args = args[1:]

    if not args:
        sys.stderr.write("用法: json_query.py [-r|-e|-c] '<expr>' [file]\n")
        sys.exit(2)

    expr = args[0]
    file_path = args[1] if len(args) > 1 else None

    try:
        data = load_data(file_path)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        sys.stderr.write("JSON 解析错误: {}\n".format(e))
        sys.exit(1)

    # 受限的全局环境，仅暴露安全内建函数
    safe_globals = {
        '__builtins__': {
            'len': len, 'str': str, 'int': int, 'float': float,
            'bool': bool, 'list': list, 'dict': dict, 'tuple': tuple,
            'set': set, 'enumerate': enumerate, 'range': range,
            'sorted': sorted, 'reversed': reversed, 'zip': zip,
            'map': map, 'filter': filter, 'any': any, 'all': all,
            'min': min, 'max': max, 'sum': sum, 'abs': abs,
            'isinstance': isinstance, 'print': print,
            'True': True, 'False': False, 'None': None,
        }
    }

    try:
        result = eval(expr, safe_globals, {'d': data, 'data': data})
    except Exception as e:
        sys.stderr.write("表达式求值错误: {}\n".format(e))
        sys.exit(1)

    # 存在性检查模式
    if exists:
        if result is None or result is False or result == '' or result == 0:
            sys.exit(1)
        sys.exit(0)

    if result is None:
        return

    # 原始输出模式
    if raw:
        if isinstance(result, list):
            for item in result:
                print(item)
        elif isinstance(result, str):
            print(result)
        else:
            print(result)
        return

    # JSON 输出模式
    if isinstance(result, (list, dict)):
        if compact:
            print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
        else:
            print(json.dumps(result, ensure_ascii=False))
    elif isinstance(result, bool):
        print('true' if result else 'false')
    else:
        print(result)


if __name__ == '__main__':
    main()

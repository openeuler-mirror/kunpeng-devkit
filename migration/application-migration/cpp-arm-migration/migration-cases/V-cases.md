# 版本兼容性案例库（V 系列）— 脱敏样例

> 仅保留 V-01 一条案例作为格式参考。

| ID | 起始行 | 摘要 |
|----|--------|------|
| V-01 | 7 | 依赖库版本不兼容导致头文件冲突 |

---

### V-01：依赖库版本不兼容导致头文件冲突

**错误现象：**
```
error: '<类名>' has no member named '<方法名>'
fatal error: <头文件路径>: No such file or directory
```

**根因分析：**
x86 预编译依赖库版本与 ARM 环境自带的版本不兼容。`_GLIBCXX_USE_CXX11_ABI` 宏设置不同导致 C++ 标准库 ABI 不兼容，预编译 .so 在 ARM 上无法正确链接。ARM 需要源码编译匹配版本并设置 `ABI=0`。

**修复方法：**

修改前：
```python
# WORKSPACE 中使用 x86 预编译依赖
http_archive(
    name = "<dep>_x86",
    urls = ["https://<仓库地址>/<dep>-x86-<版本>.tar.gz"],
)
```

修改后：
```python
# WORKSPACE 中添加 ARM 源码编译依赖
http_archive(
    name = "<dep>_aarch64",
    urls = ["https://<源码地址>/<dep>/archive/v<版本>.tar.gz"],
    strip_prefix = "<dep>-<版本>",
)

# BUILD 中条件选择
<dep>_dep = select({
    "//<platforms>:is_aarch64": "@<dep>_aarch64//:<target>",
    "//<platforms>:is_x86_64": "@<dep>_x86//:<target>",
    "//conditions:default": "@<dep>_x86//:<target>",
})
```

**适用场景：**
使用 Bazel 构建的 C/C++ 项目，x86 使用预编译依赖、ARM 需源码编译不同版本

**验证方式：**
```bash
bazel build //... --config=linux_aarch64
```

**扫描规则：**
（V 系列不填写扫描规则）

---

# 通用 ARM 适配案例库（G 系列）— 脱敏样例

> 仅保留 G-01 一条案例作为格式参考。

| ID | 起始行 | 摘要 |
|----|--------|------|
| G-01 | 7 | x86 专属编译标志在 ARM 上不支持 |

---

### G-01：x86 专属编译标志在 ARM 上不支持

**错误现象：**
```
error: unrecognized command line option '<x86-编译标志>'
```

**根因分析：**
x86 专属编译标志在 ARM GCC 中不存在。x86 上用于自动检测 CPU 类型或启用特定指令集（FMA/AVX2/AVX-512）的标志，ARM 对应不同的编译选项。

**修复方法：**

修改前：
```bash
build --copt=<x86-编译标志>
```

修改后：
```bash
##===x86特定配置===##
build:linux_x86 --cpu=k8
build:linux_x86 --copt=<x86-编译标志>

##===aarch64特定配置===##
build:linux_aarch64 --cpu=aarch64
build:linux_aarch64 --copt=-march=armv8.2-a
```

**适用场景：**
使用 Bazel 构建的 C/C++ 项目从 x86 迁移到 ARM，.bazelrc 中包含 x86 专属编译标志

**验证方式：**
```bash
bazel build //... --config=linux_aarch64
```

**扫描规则：**
DevKit 已覆盖此类型，无需加入自定义扫描规则

---

# SCons 构建系统依赖分析

> ⚠️ **按需加载**：主要用于**纯 SCons 项目**（有 `SConstruct` 且无 `BLADE_ROOT`）时加载本文件。若项目同时有 `BLADE_ROOT`（即使用 Blade），以 Blade 分析为主，不加载本文件；但仍可参考本文件「SCons 关键检查项」一节检查 `SConstruct` 中的 x86 编译标志。

---

## 读取 SCons 构建文件

```bash
# 读取 SConstruct 主文件
cat <项目根目录>/SConstruct

# 读取所有 SConscript 子文件
find <项目根目录> -name "SConscript" -type f | sort
```

---

## SCons 依赖声明方式

| SCons 语法 | 含义 | ARM 迁移关注点 |
|-----------|------|---------------|
| `env.Program('foo', ['foo.cc'], LIBS=['bar'])` | 链接系统库 | 检查系统库在 ARM 上是否可用 |
| `env.SharedLibrary('bar', ['bar.cc'])` | 构建共享库 | 检查源码中 x86 专属指令 |
| `env.StaticLibrary('baz', ['baz.cc'])` | 构建静态库 | 同上 |
| `env.Append(CXXFLAGS=['-msse4'])` | 编译标志 | ⚠️ x86 专属标志，ARM 需条件化或移除 |
| `env.Append(LIBPATH=['/usr/lib64'])` | 库搜索路径 | 检查路径在 ARM 上是否存在（ARM 通常为 `/usr/lib64` 或 `/usr/lib/aarch64-linux-gnu`） |
| `env.ParseConfig('pkg-config --cflags --libs foo')` | 通过 pkg-config 获取依赖 | 在 ARM 上重新执行 pkg-config 获取正确的 ARM 路径 |

---

## SCons 关键检查项

```bash
# 检查 SConstruct 中硬编码的 x86 编译标志
grep -rn "-msse\|-mavx\|-mf16c\|-mpopcnt\|-m64" <项目根目录>/SConstruct <项目根目录>/*/SConscript

# 检查硬编码的库路径
grep -rn "/usr/lib64\|/lib64\|/usr/lib/x86_64" <项目根目录>/SConstruct <项目根目录>/*/SConscript

# 检查 SCons 版本
scons --version
```

---

## SCons 版本兼容性

| SCons 版本 | Python 支持 | ARM 关注点 |
|-----------|------------|------------|
| SCons 2.x | 仅 Python 2 | ⚠️ 不支持 Python 3，无法在现代 ARM 系统上运行 |
| SCons 3.x | Python 2 + 3 | ✅ 基本可用，但缺少 aarch64 优化支持 |
| SCons 4.x+ | 仅 Python 3 | ✅ 推荐，原生支持 aarch64 架构检测 |

> 若项目自带 SCons（如 `builder/scons/bin/scons`），注意其版本可能仅支持 Python 2（如 SCons 2.3.0）。
> 在 ARM 环境上若系统 Python 为 3.x，需安装系统级 SCons 4.x 或通过 Blade 间接调用。

---

## SCons 注意事项

- Blade 内部集成 SCons 作为构建引擎，纯 SCons 项目（无 BLADE_ROOT）需单独分析
- 关注 `env.Append(CXXFLAGS=['-m64'])` 等 x86 编译标志和硬编码库路径
- SCons 2.x 不支持 Python 3，需使用 SCons 4.x+ 或 Blade 自带的 SCons（通过 `builder/scons/bin/scons` 调用，但注意版本兼容性）

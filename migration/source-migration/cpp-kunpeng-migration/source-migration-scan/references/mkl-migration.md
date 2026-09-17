# Intel MKL 函数替换案例

> **做什么**：将 Intel MKL（Math Kernel Library）函数（如 `cblas_sgemm`）替换为 aarch64 平台等价的数学库函数（KML 或 OpenBLAS）（修改级别 `Rule`，必须）。

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | DevKit 报告条目 | `PortingCategory.INVALID_CATEGORY` + 文件路径 + 行号 + MKL 函数名 |
| 输入 | `MKL_STRATEGY` | 阶段 2 用户决策（`kml` / `openblas` / `disable`） |
| 输出 | 源码 + 构建系统修改 | 头文件按架构切换；链接库替换为 KML 或 OpenBLAS |

## 替代方案选择

| `MKL_STRATEGY` | 数学库 | 安装方式 | 链接库 |
|----------------|--------|---------|--------|
| `kml` | 鲲鹏 KML（Kunpeng Math Library） | dnf/yum 安装 BoostKit | `-lkml_blas -lkml_lapack` |
| `openblas` | 开源 OpenBLAS | dnf/apt/源码编译 | `-lopenblas` |
| `disable` | — | 整体禁用该模块 | — |

> **核心结论**：KML 与 OpenBLAS 均实现了标准 CBLAS/LAPACK 接口，**函数签名与 Intel MKL 完全相同，只需切换链接库即可，无需修改函数调用代码本身**。

## 修改案例

### 案例 1：头文件引用修改

```cpp
// 原始代码（引用 Intel MKL 头文件）
#include "mkl.h"         // Intel MKL 主头文件
// 或
#include "mkl_cblas.h"   // Intel MKL CBLAS 接口

// 修改后（aarch64 切换为标准 CBLAS 头文件，x86 保留 MKL）
#if defined(__aarch64__)
#include "cblas.h"       // KML / OpenBLAS 均提供标准 CBLAS 接口
// KML 头文件路径：/usr/local/kml/include/cblas.h
// OpenBLAS 头文件路径：/usr/include/cblas.h 或 /usr/local/openblas/include/cblas.h
#else
#include "mkl.h"
#endif
```

### 案例 2：MKL 函数 API 兼容（无需改代码）

| Intel MKL 函数 | 说明 | KML 替换（`MKL_STRATEGY=kml`） | OpenBLAS 替换（`MKL_STRATEGY=openblas`） | 是否需改代码 |
|---------------|------|---------|---------|------------|
| `cblas_sgemm` | 单精度矩阵乘（BLAS Level 3） | `cblas_sgemm`（KML） | `cblas_sgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_dgemm` | 双精度矩阵乘（BLAS Level 3） | `cblas_dgemm`（KML） | `cblas_dgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_cgemm` | 复数单精度矩阵乘 | `cblas_cgemm`（KML） | `cblas_cgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_zgemm` | 复数双精度矩阵乘 | `cblas_zgemm`（KML） | `cblas_zgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_sgemv` | 单精度矩阵向量乘 | `cblas_sgemv`（KML） | `cblas_sgemv`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_dgemv` | 双精度矩阵向量乘 | `cblas_dgemv`（KML） | `cblas_dgemv`（OpenBLAS） | 否，仅切换链接库 |
| `LAPACKE_sgetrf` | LU 分解 | `LAPACKE_sgetrf`（KML） | `LAPACKE_sgetrf`（OpenBLAS） | 否，仅切换链接库 |

### 案例 3：构建系统链接修改（按 MKL_STRATEGY 二选一）

#### （a）`MKL_STRATEGY=kml`：链接 KML

**Bazel 项目**（`.bazelrc` 或 `BUILD` 文件）：

```python
# 原始（链接 Intel MKL）
# --linkopt=-lmkl_rt 或 --linkopt=-lmkl_intel_lp64

# 修改后（aarch64 链接 KML，x86 保留 MKL）
# .bazelrc
build:linux_aarch64 --linkopt=-L/usr/local/kml/lib/
build:linux_aarch64 --linkopt=-lkml_blas
build:linux_aarch64 --linkopt=-lkml_lapack
```

**CMake 项目**：

```cmake
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    # 链接 KML
    include_directories(/usr/local/kml/include/)
    link_directories(/usr/local/kml/lib/)
    target_link_libraries(${TARGET_NAME} kml_blas kml_lapack)
else()
    # x86 保留 MKL 链接（不修改）
    target_link_libraries(${TARGET_NAME} mkl_rt)
endif()
```

**Make 项目**：

```makefile
ifeq ($(shell uname -m),aarch64)
    # Rule（必须）：替换 MKL 为 KML
    CFLAGS   += -I/usr/local/kml/include/
    LDFLAGS  := $(patsubst -lmkl%,,$(LDFLAGS))   # 移除所有 -lmkl* 选项
    LDFLAGS  += -L/usr/local/kml/lib/ -lkml_blas -lkml_lapack
endif
```

#### （b）`MKL_STRATEGY=openblas`：链接 OpenBLAS

**Bazel 项目**（`.bazelrc` 或 `BUILD` 文件）：

```python
# 原始（链接 Intel MKL）
# --linkopt=-lmkl_rt 或 --linkopt=-lmkl_intel_lp64

# 修改后（aarch64 链接 OpenBLAS，x86 保留 MKL）
# .bazelrc
build:linux_aarch64 --linkopt=-L/usr/local/openblas/lib/
build:linux_aarch64 --linkopt=-lopenblas
# 若通过系统包管理器安装，OpenBLAS 默认在 /usr/lib64，可省略 -L
```

**CMake 项目**：

```cmake
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    # 链接 OpenBLAS
    find_package(OpenBLAS REQUIRED)
    target_link_libraries(${TARGET_NAME} ${OpenBLAS_LIBRARIES})
else()
    # x86 保留 MKL 链接（不修改）
    target_link_libraries(${TARGET_NAME} mkl_rt)
endif()
```

**Make 项目**：

```makefile
ifeq ($(shell uname -m),aarch64)
    # Rule（必须）：替换 MKL 为 OpenBLAS
    CFLAGS   += -I/usr/local/openblas/include/
    LDFLAGS  := $(patsubst -lmkl%,,$(LDFLAGS))   # 移除所有 -lmkl* 选项
    LDFLAGS  += -L/usr/local/openblas/lib/ -lopenblas
    # 若通过系统包管理器安装，可省略 -I/-L，直接 -lopenblas
endif
```

## MKL 专有扩展接口处理

> **注意**：若代码中使用了 MKL 专有扩展接口（如 `mkl_malloc`、`mkl_set_num_threads` 等），则需要额外处理：

| MKL 专有扩展 | 替代方案 |
|-------------|---------|
| `mkl_malloc` | `aligned_alloc`（C11 标准） |
| `mkl_set_num_threads` | OpenMP `omp_set_num_threads` |
| `mkl_get_version_string` | 自行实现版本号获取 |
| `mkl_free` | `free`（标准库） |

## 执行流程

1. **定位**：使用文件读取工具跳转到 DevKit 报告中的行号
2. **应用案例 1**：头文件用架构宏切换
3. **无需修改函数调用**：参考案例 2，仅切换链接库
4. **按 `MKL_STRATEGY` 应用案例 3**：KML 或 OpenBLAS 对应构建系统配置
5. **检查 MKL 专有扩展**：若代码使用 `mkl_malloc` 等扩展，按上表替换
6. **验证**：双架构编译通过（参考 [source-migration-scan.md](source-migration-scan.md) 4.3 节）

## 失败处置

| 现象 | 处置 |
|------|------|
| 链接报 `undefined reference to cblas_sgemm` | 确认 `-L` 路径正确；KML 检查 `libkml_blas.so` 是否安装；OpenBLAS 检查 `libopenblas.so` |
| KML 头文件找不到 | 检查 4.2.5.1(a) 是否成功安装；KML 默认路径 `/usr/local/kml/include/` |
| OpenBLAS 头文件找不到 | 包管理器安装路径通常在 `/usr/include/aarch64-linux-gnu/`；源码安装则在 `/usr/local/openblas/include/` |
| x86 侧编译报 `cblas_sgemm` 未定义 | 检查 `__aarch64__` 分支是否正确隔离，x86 侧应仍链接 `-lmkl_rt` |
| 使用了 `mkl_malloc` 等专有扩展 | 参考「MKL 专有扩展接口处理」表手动替换 |

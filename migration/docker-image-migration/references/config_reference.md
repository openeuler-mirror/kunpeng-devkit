## 配置规则

- 本文件是配置参考和默认值来源；不要把示例域名当成真实配置。
- 配置值优先级：用户本次明确输入 > 已填写配置 > 本文件默认值。
- `<...>` 表示必须替换的占位符；空列表使用 `[]`，不要保留示例注释作为值。

### 配置摘要

| 配置                              | 类型         | 默认值                                                       | 必填条件              | 说明                                                         |
| --------------------------------- | ------------ | ------------------------------------------------------------ | --------------------- | ------------------------------------------------------------ |
| `WORKER_COUNT`                    | integer      | `3`                                                          | 否                    | 并发执行单元数，取值 1-5；1=单任务模式，2-5=并发模式         |
| `WORKER_STALL_TIMEOUT_MIN`        | integer      | `20`                                                         | 否                    | 子 Agent 无进展等待时间（分钟），建议为 `BUILD_TIMEOUT_MIN` 的 1/3 |
| `OUTPUT_TAG_PREFIX`               | string       | `arm64`                                                      | 否                    | 生成镜像的 tag 前缀，格式 `<prefix>-<project>:latest`        |
| `OUTPUT_DOCKERFILE_DIR`           | string       | `arm_builds_{date}/dockerfiles/{project}`                    | 否                    | 生成 Dockerfile 的存储目录，`{date}`/`{project}` 自动替换    |
| `REPORT_DIR`                      | string       | `arm_builds_{date}/build_reports`                            | 否                    | 构建报告输出目录，`{date}` 自动替换                          |
| `MAX_RETRY`                       | integer      | `5`                                                          | 否                    | 单次构建最大重试次数，超出标记 `FAILED(EXCEEDED_ATTEMPTS)`   |
| `BUILD_TIMEOUT_MIN`               | integer      | `60`                                                         | 否                    | 单次构建超时时间（分钟），超出标记 `FAILED(TIMEOUT)`         |
| `GIT_HOSTS`                       | list[string] | 无                                                           | 是                    | ARM 执行机可直连的内网 Git 域名                              |
| `INTERNAL_REGISTRIES`             | list[string] | 无                                                           | 是                    | ARM 执行机可直连的内网 Docker 镜像仓库域名                   |
| `INTERNAL_PYPI_HOSTS`             | list[string] | `[]`                                                         | `AIRGAP_MODE=true` 时 | ARM 执行机可直连的内网 PyPI 地址；无则设 `[]`                |
| `AIRGAP_MODE`                     | boolean      | `false`                                                      | 否                    | `true` 时所有依赖必须走内网，公网域名标注 `[WARN-PUBLIC-URL]` |
| `PIP_INDEX_URL`                   | string       | 阿里云 PyPI                                                  | 否                    | pip 镜像源 URL，仅 `AIRGAP_MODE=false` 时生效                |
| `PIP_TRUSTED_HOST`                | string       | 与 index 主机一致                                            | 否                    | pip 信任的域名，需与 `PIP_INDEX_URL` 主机名一致              |
| `CUDA_PACKAGES_SKIP`              | list[string] | 见 6                                                         | 否                    | 按前缀匹配删除 CUDA 相关包                                   |
| `TORCH_VERSION_MAP`               | map          | 见 6                                                         | 否                    | CUDA 版 torch → CPU-only 版本映射                            |
| `FORCE_VERSION_OVERRIDES`         | map          | `networkx>=2.6`                                              | 否                    | 在 Dockerfile 末尾追加 `pip install` 覆盖指定包版本          |
| `X86_AI_MIGRATION_DIR`            | string       | 无                                                           | 远程采集时必填        | x86_64 采集机上 ai-migration 工具包目录的绝对路径（优先 `/opt/huawei/devkit` 安装目录，无则工作目录） |
| `X86_HOST`                        | string       | 无                                                           | 远程采集时必填        | x86_64 采集机 SSH 地址，格式 `<user>@<host>`                 |
| `AI_MIGRATION_TOOL_VERSION`       | string       | `26.2.T5`                                                    | 否                    | ai-migration 工具包版本号，用于拼装下载 URL（下载路径与文件名均含此版本号）；定位步骤用 `*` 通配，不受此值约束 |
| `AI_MIGRATION_TOOL_DOWNLOAD_BASE` | string       | `https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit` | 否                    | 工具包下载基址（OBS 根目录，不含版本号）。下载 URL = `${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-<arch>.tar.gz`（ARM64 用 `Kunpeng`，x86_64 用 `x86-64`） |

## 目录

- [1. 执行与并发参数](#1-执行与并发参数)
- [2. 构建输出](#2-构建输出)
- [3. 内网仓库地址（必填）](#3-内网仓库地址必填)
- [4. 内网隔离模式](#4-内网隔离模式)
- [5. pip 镜像源](#5-pip-镜像源)
- [6. CUDA / GPU 包处理](#6-cuda--gpu-包处理)
- [7. 版本强制覆盖](#7-版本强制覆盖)
- [8. x86_64 远程采集配置](#8-x86_64-远程采集配置)
- [9. 工具包版本与下载](#9-工具包版本与下载)
- [10. 默认常量（不可配）](#10-默认常量不可配)

---

## 1. 执行与并发参数

本节仅定义参数取值；调度与恢复遵循主 Skill 的全局约束。参数说明详见上方配置摘要表。

---

## 2. 构建输出

| 配置                    | 默认值                                      |
| ----------------------- | ------------------------------------------- |
| `OUTPUT_TAG_PREFIX`     | `"arm64"`                                   |
| `OUTPUT_DOCKERFILE_DIR` | `"arm_builds_{date}/dockerfiles/{project}"` |
| `REPORT_DIR`            | `"arm_builds_{date}/build_reports"`         |
| `MAX_RETRY`             | `5`                                         |
| `BUILD_TIMEOUT_MIN`     | `60`（分钟）                                |

---

## 3. 内网仓库地址（必填）

> **启动前必须确认**：以下三项中所有 `<...>` 占位符已替换为实际值，否则主 Agent 启动校验不通过。

| 配置                  | 默认值 |
| --------------------- | ------ |
| `GIT_HOSTS`           | 无     |
| `INTERNAL_REGISTRIES` | 无     |
| `INTERNAL_PYPI_HOSTS` | `[]`   |

---

## 4. 内网隔离模式

| 配置          | 默认值  |
| ------------- | ------- |
| `AIRGAP_MODE` | `false` |

---

## 5. pip 镜像源

> 仅当 `AIRGAP_MODE=false` 时生效；`true` 时使用 `INTERNAL_PYPI_HOSTS[0]`。

| 配置               | 默认值                                      |
| ------------------ | ------------------------------------------- |
| `PIP_INDEX_URL`    | `"https://mirrors.aliyun.com/pypi/simple/"` |
| `PIP_TRUSTED_HOST` | `"mirrors.aliyun.com"`                      |

---

## 6. CUDA / GPU 包处理

> 本 Skill 默认面向无 NVIDIA GPU 的鲲鹏 CPU 场景。以下配置控制 CUDA 相关包的删除与 CPU 版本替换；目标 ARM64 环境具备受支持的 GPU/CUDA 栈时，应显式调整这些配置。

| 配置                 | 默认值                                            |
| -------------------- | ------------------------------------------------- |
| `CUDA_PACKAGES_SKIP` | `["nvidia-", "triton", "cuda-", "cudnn", "nccl"]` |
| `TORCH_VERSION_MAP`  | 见下表                                            |

**`TORCH_VERSION_MAP` 默认映射**：

| CUDA 版                                       | CPU-only 替代 |
| --------------------------------------------- | ------------- |
| `2.8.0+cu124` / `2.7.0+cu124` / `2.6.0+cu124` | `2.6.0`       |
| `2.5.0+cu121` / `2.4.0+cu121`                 | `2.4.1`       |
| `2.3.0+cu121`                                 | `2.3.1`       |
| `2.2.0+cu121`                                 | `2.2.2`       |
| `2.1.0+cu118`                                 | `2.1.2`       |
| `2.0.0+cu118`                                 | `2.0.1`       |

> 如需锁定特定版本，可在此补充映射关系。其他 `+cuXXX` 版本先验证 CPU-only 包是否存在，再决定是否去掉后缀。

---

## 7. 版本强制覆盖

| 配置                      | 默认值                  |
| ------------------------- | ----------------------- |
| `FORCE_VERSION_OVERRIDES` | `{"networkx": ">=2.6"}` |

| 包         | 覆盖版本 | 原因                                                         |
| ---------- | -------- | ------------------------------------------------------------ |
| `networkx` | `>=2.6`  | networkx 2.2 在 Python 3.10 不兼容（`collections.Mapping` 已移除） |

---

## 8. x86_64 远程采集配置

> 仅当当前机器为 ARM64 且需要远程 x86_64 采集机时生效。完整环境检查流程见 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md)。

| 配置                   | 默认值     | 说明                                                         |
| ---------------------- | ---------- | ------------------------------------------------------------ |
| `X86_HOST`             | 无（必填） | x86_64 采集机 SSH 地址，格式 `<user>@<host>`                 |
| `X86_AI_MIGRATION_DIR` | 无（必填） | x86_64 采集机上 ai-migration 工具包目录的绝对路径（优先为 DevKit 安装目录 `/opt/huawei/devkit` 下，如 `/opt/huawei/devkit/DevKit-AI-Migration-Tool-<version>-Linux-x86-64`；无则工作目录下，如 `<工作目录>/DevKit-AI-Migration-Tool-<version>-Linux-x86-64`；工具包获取方式见 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md) 步骤 2/2.1） |

**使用示例**：

```bash
X86_HOST=user@192.168.1.100
X86_AI_MIGRATION_DIR=/home/user/arm_builds_20260831/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64
```

> x86_64 采集机上的所有操作通过 `${X86_AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>` 调用。

---

## 9. 工具包版本与下载

> 工具包版本号与下载基址在此集中维护。**定位步骤一律用 `*` 通配**（`ls /opt/huawei/devkit/DevKit-AI-Migration-Tool-*/ai-migration`、`ls <工作目录>/DevKit-AI-Migration-Tool-*/ai-migration`），匹配任意已安装版本，**不依赖本节版本号**；本节版本号仅用于拼装下载 URL。

| 配置                              | 默认值                                                       | 说明                                                         |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `AI_MIGRATION_TOOL_VERSION`       | `26.2.T5`                                                    | ai-migration 工具包版本号，下载路径与文件名均含此版本号，下游下载步骤经 `${AI_MIGRATION_TOOL_VERSION}` 引用 |
| `AI_MIGRATION_TOOL_DOWNLOAD_BASE` | `https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit` | 工具包下载基址（OBS 根目录，不含版本号）。下载 URL = `${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-<arch>.tar.gz`（ARM64 用 `Kunpeng`，x86_64 用 `x86-64`） |

**使用示例**：

```bash
# 下载 URL 拼装（ARM64 主控端）
curl -LO ${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-Kunpeng.tar.gz

# 下载 URL 拼装（x86_64 采集机）
curl -LO ${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64.tar.gz
```

> 定位与获取的完整优先级（`/opt/huawei/devkit` → 工作目录 → 下载 → 跨机传输 → 请求用户）见 SKILL.md「工具定位」与 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md) 步骤 2/2.1。下载属系统环境变更，执行前须按 SKILL.md「系统环境变更确认」请求用户确认。若上述直链失效（如版本目录调整），可在 DevKit 下载门户 `https://kunpeng-community.rnd.huawei.com/zh/developer/devkit/downloadNew` 手动查找对应架构与版本的工具包。

---

## 10. 默认常量（不可配）

以下常量在流程中硬编码使用，不在配置文件中直接修改，但可在特殊需求时参考。

| 常量                    | 值                                                           | 用途                               | 定义位置                                  |
| ----------------------- | ------------------------------------------------------------ | ---------------------------------- | ----------------------------------------- |
| `MIN_DISK_SPACE_GB`     | `10`                                                         | 每个独立容器任务的最小磁盘可用空间 | 主 Skill 全局约束                         |
| `NPM_REGISTRY`          | `https://registry.npmmirror.com`                             | npm 默认镜像源                     | `references/build_knowledge_reference.md` |
| `APACHE_MIRROR`         | `https://archive.apache.org`                                 | Apache 归档镜像                    | `references/build_knowledge_reference.md` |
| `DOCKERHUB_OFFICIAL`    | `https://registry-1.docker.io/v2/`                           | DockerHub 官方 registry            | 主 Skill 全局约束                         |
| `DOCKERHUB_MIRROR_LIST` | `mirror.ccs.tencentyun.com`, `docker.mirrors.ustc.edu.cn`, `hub-mirror.c.163.com`, `registry.cn-hangzhou.aliyuncs.com`, `mirrors.huaweicloud.com` | DockerHub 国产镜像站探测顺序       | 主 Skill 全局约束                         |
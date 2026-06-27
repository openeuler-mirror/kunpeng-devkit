# image_collector

镜像信息采集工具。从 registry 直接获取镜像的 manifest、history、layer 成分，**无需 pull 镜像到本地**，支持基础镜像与业务镜像的 diff 分析。

## 文件说明

```
image_collector/
  collect.sh               # 主入口脚本
  analyze.py               # 采集结果分析（基础镜像索引 / biz diff）
  inspect_image_env.sh     # x86 容器内 layer 成分采集（ARM 自动跳过）
  inspect_image_history.sh # history 采集兜底脚本（buildx 可用时不调用）
  inspect_image_layout.py  # 环境布局分析辅助脚本
  diff_image_env.py        # 环境 diff 辅助脚本
```

## 环境依赖

| 依赖 | 说明 |
|------|------|
| `bash` >= 4.0 | 脚本运行环境 |
| `docker` | 必须，复用其认证凭据访问 registry |
| `docker buildx` | 强烈推荐，用于不 pull 直接获取 manifest + history |
| `python3` | 必须，用于 JSON 解析和分析 |
| `skopeo` | 可选，`docker buildx` 不可用时的备选方案 |

> **ARM 机器**：layer 成分采集（`inspect_image_env.sh`）会自动跳过，manifest 和 history 仍正常采集。

## 快速开始

```bash
# 解压
tar -xzf image_collector.tar.gz
cd image_collector

# 查看帮助
bash collect.sh -h

# 采集基础镜像（单个）
bash collect.sh --mode base --image registry.example.com/base/ubuntu:20.04 --output ./out_base

# 采集基础镜像（批量列表）
bash collect.sh --mode base --list base_images.txt --output ./out_base

# 采集业务镜像并与基础镜像 diff
bash collect.sh --mode biz --list biz_images.txt --output ./out_biz --base-output ./out_base
```

## 参数说明

```
bash collect.sh [参数...]
```

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `--mode base\|biz` | ✅ | — | `base`：基础镜像模式；`biz`：业务镜像模式 |
| `--image <registry/repo:tag>` | 二选一 | — | 单个镜像，与 `--list` 互斥 |
| `--list <txt文件>` | 二选一 | — | 镜像列表文件，每行一个镜像，`#` 开头为注释 |
| `--output <目录>` | | `./collector_out` | 采集结果输出根目录 |
| `--base-output <目录>` | | — | biz 模式：指定已有基础镜像结果目录用于 diff |
| `--workers <N>` | | `4` | 并发采集数量 |
| `-h` | | — | 打印参数说明和示例命令 |

## 输出结构

```
<output>/
  <safe_image_name>/
    manifest.json          # 镜像 manifest：架构、OS、ENV、CMD、layer digests 等
    history.json           # 构建历史：每一层的 created_by 命令
    layer.json             # 容器内环境成分（x86 only，ARM 跳过）
    diff.json              # 与基础镜像的 diff（仅 biz 模式）
    _status.json           # 单镜像采集状态
  _collect_summary.json    # 本次采集汇总（所有镜像状态）
  _base_index.json         # 基础镜像索引（仅 base 模式生成）
<output>.tar.gz            # 自动打包（除非 --skip-pack）
```

### manifest.json 关键字段

```json
{
  "meta":             { "source_image": "...", "collected_at": "...", "collector": "..." },
  "architecture":     "amd64",
  "os":               "linux",
  "created":          "2026-03-16T...",
  "layers":           ["sha256:...", "..."],
  "env":              ["PATH=...", "..."],
  "cmd":              ["python", "server.py"],
  "entrypoint":       [],
  "workdir":          "/workspace",
  "labels":           {}
}
```

### history.json 关键字段

```json
{
  "meta":    { "layer_count": 13, "collector": "..." },
  "history": [
    { "created": "...", "created_by": "/bin/sh -c apt-get install ...", "empty_layer": false },
    ...
  ],
  "layers":  ["sha256:...", "..."]
}
```

### diff.json 关键字段（biz 模式）

```json
{
  "matched_base":  "registry/base:tag",
  "match_score":   0.85,
  "packages_diff": ["pkg_only_in_biz==1.2.3", "..."],
  "env_diff":      ["MY_ENV=value"],
  "os_match":      true
}
```

## 典型工作流

### 场景一：只采集基础镜像

```bash
cat > base_images.txt << 'EOF'
registry.example.com/base/ubuntu:20.04
registry.example.com/base/python:3.11-slim
EOF

bash collect.sh --mode base --list base_images.txt --output ./base_out
# 输出：./base_out.tar.gz
```

### 场景二：采集业务镜像并做 diff

```bash
# 第一步：采集基础镜像
bash collect.sh --mode base --list base_images.txt --output ./base_out

# 第二步：采集业务镜像，指定 --base-output 做 diff
bash collect.sh --mode biz --list biz_images.txt \
    --output ./biz_out \
    --base-output ./base_out \
    --workers 8
# 输出：./biz_out.tar.gz，每个镜像目录下含 diff.json
```

### 场景三：ARM 机器采集

ARM 机器上 layer 采集自动跳过，manifest 和 history 正常获取（不需要 pull）：

```bash
bash collect.sh --mode base --image registry.example.com/svc/app:v1 --output ./out
# [WARN] 检测到 ARM 架构 (arm64)，自动跳过 layer 采集
# [OK]   完成 (layer=0 history=1 manifest=1)
```

## manifest / history 采集原理

**不需要 pull 镜像**，按以下优先级尝试：

1. `docker buildx imagetools inspect --format '{{json .}}'`（首选，含完整 history）
2. `skopeo inspect docker://<image>`（备选）
3. `docker manifest inspect <image>`（仅 manifest，无 history）
4. `docker image inspect <image>`（兜底，需镜像已在本地）

认证复用本机 `docker login` 的凭据（`~/.docker/config.json`），无需额外配置。

## 1. 采集边界

| 数据文件 | 主要用途 | 是否可能触发 `docker pull` | ARM64 主机上的默认行为 |
|---|---|---|---|
| `manifest.json` | 记录镜像架构、OS、基础配置、layer digest | 通常不会；仅在本地兜底流程下，且镜像已在本地时读取本地信息 | 正常尝试采集 |
| `history.json` | 记录可见构建层和历史命令 | 通常不会；仅在本地兜底流程下，且镜像已在本地时读取本地信息 | 正常尝试采集 |
| `layer.json` | 记录容器内包、运行时、文件和环境信息 | 可能会；通常需要先拉取镜像并运行容器 | 当前 `collect.sh` 在 ARM64 主机默认跳过 |
| `diff.json` | 记录业务镜像相对基础镜像的差异 | 不会单独触发 pull（依赖已有采集结果） | 若缺少 `layer.json`，通常不生成 |

说明：`collect.sh` 返回成功不代表每个文件都成功生成。自动化调用方必须读取 `_collect_summary.json` 与各镜像的 `_status.json` 判定真实结果，不能只看脚本退出码或压缩包是否存在。

## 2. 环境依赖

| 依赖 | 要求 |
|---|---|
| Bash | 4.0 或更高版本 |
| Docker CLI/daemon | 必需；Registry 认证复用 `docker login` 凭据 |
| Python | Python 3 |
| Docker Buildx | 建议安装；优先获取 manifest 与 history |
| `skopeo` | 可选的 Registry 读取备选 |
| `openpyxl` | 仅 `diff_image_env.py` 需要 |

需要 `layer.json` 时，应在可运行源镜像的 x86_64 主机执行。即使 ARM64 主机已经注册 QEMU，当前 `collect.sh` 仍会跳过 layer 采集。

## 3. 使用方法

```bash
bash collect.sh --help

# 单个基础镜像
bash collect.sh \
  --mode base \
  --image registry.example.com/base/ubuntu:22.04 \
  --output ./out_base

# 批量基础镜像
bash collect.sh \
  --mode base \
  --list base_images.txt \
  --output ./out_base

# 业务镜像与已有基础镜像结果做差异分析
bash collect.sh \
  --mode biz \
  --list biz_images.txt \
  --output ./out_biz \
  --base-output ./out_base
```

镜像列表格式：

```text
# 每行一个镜像；空行和 # 注释被忽略
registry.example.com/team/app-a:v1
registry.example.com/team/app-b:v2
```

## 4. 参数

| 参数 | 必填 | 默认值 | 说明 |
|---|---:|---|---|
| `--mode base\|biz` | 是 | — | `base` 生成基础索引；`biz` 尝试生成差异 |
| `--image <image:tag>` | 二选一 | — | 单个镜像；与 `--list` 互斥 |
| `--list <file>` | 二选一 | — | 镜像列表；与 `--image` 互斥 |
| `--output <dir>` | 否 | `./collector_out` | 输出根目录 |
| `--base-output <dir>` | 否 | — | `biz` 模式的基础镜像结果目录；缺省时跳过差异分析 |
| `--workers <N>` | 否 | `4` | 并发采集数，必须为正整数 |
| `--timeout <seconds>` | 否 | `300` | 单项 layer 采集超时，必须为正整数 |
| `-h`, `--help` | 否 | — | 显示帮助 |

## 5. 输出与判定

```text
<output>/
  <safe_image_name>/
    manifest.json
    history.json
    layer.json
    diff.json
    _status.json
  _collect_summary.json
  _base_index.json
<output>.tar.gz
```

文件按实际能力生成：`layer.json`、`diff.json` 和 `_base_index.json` 可能缺失。

单镜像状态示例：

```json
{
  "image": "registry.example.com/team/app:v1",
  "got_layer": false,
  "got_history": true,
  "got_manifest": true
}
```

Agent 使用采集结果时按以下顺序判断：

1. `_status.json` 可解析；
2. `got_manifest`、`got_history`、`got_layer` 与实际文件一致；
3. 所需信息缺失时在决策矩阵和报告中记录，不把部分采集写成完整成功；
4. `image-reconstruction/SKILL.md 1.6` 只读取实际存在且可解析的产物。

## 6. Registry 读取优先级

manifest/history 按以下顺序尝试：

1. `docker buildx imagetools inspect --format '{{json .}}'`；
2. `skopeo inspect docker://<image>`；
3. `docker manifest inspect <image>`，只保证 manifest；
4. `docker image inspect` 和 `docker history`，要求镜像已在本地。

layer 采集独立于上述顺序：在 x86_64 主机上，镜像不在本地时会先尝试 `docker pull`；脚本只清理由本次执行拉取的镜像。

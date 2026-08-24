# 阶段 1 待确认项（stage_1_pending_items）

> 本文件由阶段 1 子 agent 写入，供主 agent 在阶段 3 统一向用户提问。
> 若无待确认项，写入空清单并标注"无待确认项"。

---

## 待确认项格式

每条待确认项为一个 YAML 代码块，`id` 以 `env_` 为前缀：

```yaml
- id: env_<名称>            # env_ 前缀，如 env_blade_version
  category: 环境检测
  question: "<具体问题，描述需要用户决策的内容>"
  options:
    - id: <选项id>           # 如 upgrade、skip、manual
      label: "<选项标签>"    # 如 升级到 Blade 2.0、跳过、手动处理
  context: "<决策依据，描述检测到的现状和影响>"
```

---

## 填写示例

```yaml
- id: env_blade_version
  category: 环境检测
  question: "项目中的 Blade 版本为 1.x，不支持鲲鹏和 Python3，是否升级到 Blade 2.0？"
  options:
    - id: upgrade_2
      label: "升级到 Blade 2.0（推荐，减少跨版本跨度）"
    - id: upgrade_3
      label: "升级到 Blade 3.0（最新版本，跨度较大）"
    - id: skip
      label: "跳过，手动处理"
  context: "检测到项目 blade.zip 版本为 1.8.0，该版本不支持 aarch64 架构和 Python3，必须升级才能在鲲鹏上构建。"
```

```yaml
- id: env_bazel_not_found
  category: 环境检测
  question: "鲲鹏环境未找到 Bazel，项目所需版本为 4.0.0，自动安装失败，请选择处理方式。"
  options:
    - id: retry_internal
      label: "提供内部定制版下载链接后重试"
    - id: manual
      label: "手动安装，安装完成后继续"
  context: "项目 .bazelversion 文件指定版本 4.0.0，自动从 build-tools-reference.md 获取链接后 wget 失败（网络超时），需用户介入。"
```

```yaml
- id: env_disk_space_project_root
  category: 环境检测
  question: "项目根目录所在分区可用空间不足，迁移过程涉及依赖源码签出、子模块更新、构建工具下载和编译产物写入，请选择处理方式。"
  options:
    - id: change_workdir
      label: "更改产物落盘地址到空间充足的分区"
    - id: abort
      label: "中止迁移"
  context: "项目代码大小 500 MB，估算所需空间 2.5 GB，项目根目录 /data/projects/myapp 所在分区 /data 可用空间 1.1G，不足 1.4 GB。"
```

---

## 实际输出示例（无待确认项）

```yaml
# 无待确认项
# 所有依赖已就绪或已在本阶段自动处理完成
```

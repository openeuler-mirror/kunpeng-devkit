## 阶段 2 决策矩阵模板

> 用途：完成阶段 1 分析后，逐项填写本矩阵；所有条目必须填写完毕后才可进入阶段 3。

> **适用场景边界（务必遵守）**：本模板仅适用于"无 Dockerfile（仅镜像迁移）场景"，即 `references/image_reconstruction.md` 阶段 2 引用的决策矩阵。
> - 有 Dockerfile 场景（走 `references/dockerfile_migration.md`）：不读取本文件，阶段 2 使用该场景自有的"迁移决策表"，避免过度读取。
> - 场景判断以主 `SKILL.md` 的"迁移场景选择"为准；信息不足时先补齐场景输入，不要预先加载本文件。

```text
【基础信息】
[ ] FROM 基础镜像：___________
[ ] OS 版本（layer.os.pretty_name）：___________
[ ] 运行用户：___________    [ ] WORKDIR：___________
[ ] CMD/ENTRYPOINT：___________    [ ] 技术栈：___________

【不透明层】
[ ] 存在不透明层（Size > 0，CreatedBy=/bin/bash）：是 / 否
    → 是：已执行 inspect layout（--mode full，见 image_reconstruction.md 1.7），已从 directory_tree 补全

【资源获取方式】
[ ] git clone 类资源：___________
    内网（GIT_HOSTS 命中） → 直连重建 [KEEP-GIT-INTERNAL]
    内网（不可达）         → 阶段 3 docker cp [NEED-DOCKER-CP]
    外网                   → 可重建，注释提示确认网络
[ ] COPY/ADD 引入的非标准文件：___________
    大型二进制/模型文件    → 阶段 3 docker cp
    标准代码文件           → 随 git clone 重建

【架构相关】
[ ] CUDA/GPU 包（nvidia-*/triton/cu12）：有 / 无 → 按目标是否为 CPU 场景和 `CUDA_PACKAGES_SKIP` 决定
[ ] native 文件候选（文件名或路径含 x86_64/amd64）：有 / 无
    → 有：先取得 ELF/DevKit 证据，再按 (references/dockerfile_migration.md) 处理
[ ] JAR 内 native 库：有 / 无 → 有则检查 ELF 架构

【环境变量】
[ ] 关键 ENV（来自 layer.image_env；缺失时从 layout.env_vars 回退）：___________

【兼容性预检】
[ ] python.installed_packages 中已知不兼容包（查 build_knowledge_reference.md）：___________
[ ] JAR/WAR/EAR 包 native 库：
    优先： `devkit porting pkg-mig -i <extracted_jars_dir> -t openeuler22.03 -r json`
    未安装 devkit → 按 references/devkit_pkg_mig_reference.md 第 3 节 fallback 执行（解压后逐个 file），不得仅凭 unzip -l 列表判定
    发现 x86 .so → 标记 [WARN-X86-NATIVE-SO]，按三类策略处理
```
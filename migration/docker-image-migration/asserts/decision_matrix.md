## 阶段 2 决策矩阵模板

> 用途：完成阶段 1 分析后，逐项填写本矩阵；所有条目必须填写完毕后才可进入阶段 3。

```text
【基础信息】
[ ] FROM 基础镜像：___________
[ ] OS 版本（layout os.pretty_name）：___________
[ ] 运行用户：___________    [ ] WORKDIR：___________
[ ] CMD/ENTRYPOINT：___________    [ ] 技术栈：___________

【不透明层】
[ ] 存在不透明层（Size > 0，CreatedBy=/bin/bash）：是 / 否
    → 是：已执行 layout full，已从 directory_tree 补全

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
    → 有：先取得 ELF/DevKit 证据，再按 [dockerfile_migration.md](../dockerfile_migration.md) 处理
[ ] JAR 内 native 库：有 / 无 → 有则检查 ELF 架构

【环境变量】
[ ] 关键 ENV（来自 layout.environment）：___________

【兼容性预检】
[ ] pip_packages 中已知不兼容包（查 [build_knowledge_reference.md](../../references/build_knowledge_reference.md)）：___________
[ ] JAR/WAR/EAR 包 native 库：
    优先： `devkit porting pkg-mig -i <extracted_jars_dir> -t openeuler22.03 -r json`
    未安装 devkit → `unzip -l <jar> | grep "\.so\|linux"` 手动检查
    发现 x86 .so → 标记 [WARN-X86-NATIVE-SO]，按三类策略处理
```
请帮我将以下 C/C++ 项目从 x86 迁移到 ARM（鲲鹏 aarch64）。

【项目信息】
- 项目路径：<填写项目绝对路径>
- 构建系统：<Bazel / CMake / Make / Blade / SCons / 自动识别>
- 主编译目标：<填写主编译目标，不确定可留空>

【排除目录配置】（不必使用Devkit扫描这些目录的源码适配问题）
- third_party/        # 第三方库源码，由上游维护，不改动
- vendor/             # 外部依赖 vendored 源码
- deps/               # 内嵌依赖目录
- build/              # 构建产物
- out/                # 构建输出
- .git/               # 版本控制
- docs/               # 文档
- test/               # 测试目录（如不需迁移测试）
- <其他自定义排除目录>

【排除目录在各阶段的生效方式】
- 阶段 D DevKit 扫描：DevKit src-mig 支持排除参数则传入

【执行要求】
按 cpp-arm-migration skill 五阶段流程执行（A 环境检测 → B 依赖分析 → C 用户确认 → D DevKit 扫描适配 → E 编译验证循环）。
- 所有源码修改须有 __aarch64__ 架构宏保护，不破坏 x86 能力
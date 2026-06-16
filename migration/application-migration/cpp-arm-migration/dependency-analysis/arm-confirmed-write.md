# 写入 ARM 确认清单与执行真实切换

> 本文件描述阶段 C/D 中的两个动作：
> 1. **阶段 C**：用户确认某依赖兼容 ARM 后，将其登记到 [arm_confirmed.md](../arm_confirmed.md)（仅写文件，不动项目）
> 2. **阶段 D**：按已登记的 ARM 适配信息执行真实的切换（修改 WORKSPACE / 回迁目录 / 切换子模块分支等），让构建系统真正使用 ARM 版本

> ⚠️ **顺序约束**：阶段 C 的写入是登记动作，必须在 SKILL.md 阶段 C 用户通过 `AskUserQuestion` 明确确认后才执行；阶段 D 的真实切换更进一步，是在 DevKit 扫描完成、阶段 D 整体推进时执行。两步分离的目的是：登记动作可逆（仅改一个清单文件），而切换动作会修改项目源码树，需要在用户充分了解决策的前提下再做。

---

## 阶段 C：写入 ARM 确认清单

### 步骤 1：定位主仓项目区块

打开 [arm_confirmed.md](../arm_confirmed.md)，查找当前主仓的项目区块。区块标题格式：

```markdown
## <主仓名>（<构建系统>）
```

**若已存在**：直接定位到对应表格的末尾，准备追加行。

**若不存在**：在文件末尾追加一个新区块，按构建系统选用下面的模板。

### 步骤 2：按构建系统选模板写入

#### Blade 项目模板

```markdown
## <主仓名>（Blade）

### 全局编译配置
- BLADE_ROOT 中 `cc_config.cxxflags`：<ARM 配置摘要，如 `-fsigned-char` 是否已加>
- 工具链：blade 版本 <X.Y>，protoc 版本 <X.Y>
- 构建命令：`blade build <target> --toolchain-prefix=<prefix>`

### 已确认依赖
| 依赖库 | ARM 路径 | ABI | 备注 |
|--------|---------|-----|------|
| <依赖名> | thirdparty/<组件名>/<arm 子目录> | _GLIBCXX_USE_CXX11_ABI=<0/1> | <如「来自 thirdparty_arm 回迁，已替换 BUILD」> |
```

#### Bazel 项目模板

```markdown
## <主仓名>（Bazel）

### 全局编译配置
- WORKSPACE 切换方式：`cp WORKSPACE_arm WORKSPACE`（或 `--config=linux_aarch64`）
- 工具链：bazel <X.Y>，gcc <X.Y>
- 构建命令：`bazel build <target> --config=linux_aarch64 --verbose_failures`

### 已确认依赖
| 依赖库 | ARM URL / commit | 备注 |
|--------|-----------------|------|
| <依赖名> | <ARM URL 或 git commit> | <如「私有仓 arm64 分支 HEAD」> |
```

#### CMake 项目模板

```markdown
## <主仓名>（CMake）

### 全局编译配置
- 工具链文件：<toolchain.cmake 路径，若有>
- ABI：`_GLIBCXX_USE_CXX11_ABI=<0/1>`（必须与所有 ARM 依赖一致）
- 构建命令：`cmake -B build -DCMAKE_SYSTEM_PROCESSOR=aarch64 ... && cmake --build build`

### 已确认依赖
| 依赖库 | 源码位置（项目内） | ABI | 备注 |
|--------|-----------------|-----|------|
| <依赖名> | <third_party/xxx 或外部 URL> | _GLIBCXX_USE_CXX11_ABI=<0/1> | <如「FetchContent 已切到 v1.2.3-arm」> |
```

### 步骤 3：仅对当前确认项追加行

每条用户确认结果对应**一行追加**，不要批量改写已有行。已有行表示历史迁移成果，覆盖会丢失上下文。

### 步骤 4：在 user_decisions.txt 中同步留痕

阶段 C 收到用户的每条确认/否决都应记录到 `$WORK_DIR/reports/user_decisions.txt`，便于阶段 D/E 回溯：

```
[<时间戳>] <依赖名> → 已确认 ARM 兼容，arm_confirmed.md 已追加
[<时间戳>] <依赖名> → 用户选择「禁用该模块」
[<时间戳>] <依赖名> → 用户提供本地 ARM 包路径：<路径>
```

---

## 阶段 D：执行真实切换

> ⚠️ **前置**：阶段 C 已写入 arm_confirmed.md，阶段 A/B 报告齐全，DevKit 扫描已就绪或待执行。

### Blade 项目：thirdparty_arm 回迁

Blade 项目通常将 ARM 库放在 `thirdparty_arm/` 下统一管理，构建前必须回迁到 `thirdparty/` 对应位置（因为 Blade 只识别 `thirdparty/`），同时切换 BUILD 文件到 ARM 版。

```bash
# 1. 备份当前 thirdparty 状态（便于失败回滚）
cd $PROJECT_ROOT
git -C $PROJECT_ROOT status thirdparty/ > $WORK_DIR/reports/blade_thirdparty_before.txt

# 2. 对 arm_confirmed.md 中每个 Blade 依赖执行回迁
#    示例：依赖名 = boost
COMP=boost
ARM_SRC="$PROJECT_ROOT/thirdparty_arm/$COMP"
DST="$PROJECT_ROOT/thirdparty/$COMP"

if [ -d "$ARM_SRC" ]; then
    # 把 ARM 子目录拷贝/链接到 thirdparty 下
    cp -rn "$ARM_SRC"/* "$DST"/
    echo "✅ $COMP 已从 thirdparty_arm 回迁到 thirdparty"
else
    echo "⚠️ $COMP 在 thirdparty_arm 下未找到 ARM 版本"
fi

# 3. 切换 BUILD 文件到 ARM 版（若项目采用 BUILD/BUILD.x86 双架构分离）
if [ -f "$DST/BUILD.arm" ]; then
    [ -f "$DST/BUILD" ] && mv "$DST/BUILD" "$DST/BUILD.x86"
    cp "$DST/BUILD.arm" "$DST/BUILD"
    echo "✅ $COMP BUILD 已切换到 ARM 版"
fi
```

> **不要 `git add` thirdparty_arm 回迁产物**：这些是构建时工件，最终修改清单中只应包含 BUILD 文件级的变更，二进制库回迁是可重复的部署动作。

### Bazel 项目：WORKSPACE 切换

Bazel 项目通常以 `WORKSPACE` / `WORKSPACE_arm` 双文件并存的方式管理双架构。临时复制即可，编译后清理：

```bash
cd $PROJECT_ROOT

# 1. 备份原 WORKSPACE（若 git 已跟踪则跳过）
[ -f WORKSPACE ] && [ ! -f WORKSPACE.x86_backup ] && cp WORKSPACE WORKSPACE.x86_backup

# 2. 切到 ARM 版（若项目使用 software.sh 等封装则源码已自动处理，跳过此步）
if [ -f WORKSPACE_arm ]; then
    cp WORKSPACE_arm WORKSPACE
    echo "✅ WORKSPACE 已切换到 ARM 版"
fi

# 3. 切换私有 git_repository 子模块到 ARM 分支（仅对 arm_confirmed.md 中标了 ARM 分支的依赖）
#    示例：依赖名 = my-internal-lib，分支 = arm64
DEP_DIR=$(bazel info output_base 2>/dev/null)/external/my_internal_lib
if [ -d "$DEP_DIR" ]; then
    git -C "$DEP_DIR" fetch origin arm64
    git -C "$DEP_DIR" checkout arm64
fi
```

> ⚠️ **WORKSPACE 文件管理**：阶段 E 编译成功后必须 `rm WORKSPACE`（保留 `WORKSPACE_arm` 和 `WORKSPACE.x86_backup`），避免错把 ARM 版的临时 WORKSPACE 提交到 master。该清理动作已在 [sourcecode-build-verify.md](../sourcecode-build-verify.md) E.8 节落实。

### CMake 项目：清缓存 + 切子模块分支

CMake 切换最易踩的两个坑：①`CMakeCache.txt` 缓存 x86 路径；②**子模块自动签出在 cmake 阶段把手动切的 ARM 分支默默重置回去**。

> 🚨 **第二步「注释自动签出」是 CMake 项目阶段 D 的关键关卡 —— 不可跳过**：
>
> 阶段 B 依赖分析报告中已识别到的自动签出逻辑（如 `execute_process(... git submodule update ...)`、`FetchContent_MakeAvailable`），**必须在切换子模块分支之前先注释或参数化**。否则下面第 4 步的 `cmake -B build` 会"恢复"未初始化子模块的初衷把刚切到 ARM 分支的子模块重置回默认分支，且**全程不报错**——后续编译会出现"明明切了 ARM 分支但报 x86 残留错误"的诡异现象，极易误判为依赖问题，浪费数小时。
>
> 该步骤完成后，必须在 `$WORK_DIR/reports/user_decisions.txt` 留痕：
> ```
> [<时间戳>] CMake 自动签出逻辑已注释/参数化：<具体文件:行号>
> ```

```bash
cd $PROJECT_ROOT

# 1. 完全清理 build 目录（不要只 rm CMakeCache.txt，部分模块会有自己的缓存）
rm -rf build/

# 2. 🚨 注释/参数化自动签出逻辑（阶段 B 报告里已识别的位置）
#    人工核对后，将 CMakeLists.txt 中类似下面的语句改为可控开关：
#      execute_process(COMMAND git submodule update --init --recursive ...)
#    建议改为：
#      option(AUTO_SUBMODULE "Auto checkout submodules" ON)
#      if(AUTO_SUBMODULE)
#        execute_process(COMMAND git submodule update --init --recursive ...)
#      endif()
#    并在 ARM 配置中传 `-DAUTO_SUBMODULE=OFF`
#    ⚠️ 不要直接删除原语句，保留开关让 x86 编译路径不受影响（双架构兼容原则）

# 3. 对 arm_confirmed.md 中标了 ARM 分支的子模块手动切换
#    示例：third_party/foo 切到 arm64 分支
git -C $PROJECT_ROOT/third_party/foo fetch origin arm64
git -C $PROJECT_ROOT/third_party/foo checkout arm64

# 4. 重新生成（带 ARM 工具链参数 + 关闭自动签出）
cmake -B build -S $PROJECT_ROOT \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DAUTO_SUBMODULE=OFF

# 5. 验证子模块分支没有被 cmake 重置
git -C $PROJECT_ROOT/third_party/foo branch --show-current
# 期望输出：arm64
# 若输出非 arm64 → 第 2 步失败，回到第 2 步检查是否还有遗漏的自动签出语句
```

---

## 切换后验证清单

执行真实切换后，进入阶段 E 编译前先做基础校验，避免把简单的路径错误带进编译循环：

- [ ] arm_confirmed.md 中每条已确认依赖，对应的 ARM 路径/URL 在项目里**确实存在**
- [ ] Blade：`thirdparty/<组件>/` 下能找到 `lib*.so` 且 `file lib*.so` 输出含 `aarch64`
- [ ] Bazel：`WORKSPACE` 当前内容来自 `WORKSPACE_arm`（`diff WORKSPACE WORKSPACE_arm` 应无差异）
- [ ] CMake：`rm -rf build/` 已执行；🚨 自动签出逻辑已注释/参数化（在 user_decisions.txt 留痕）；切换分支后 `git branch --show-current` 验证子模块分支未被重置
- [ ] 对阶段 C 中用户回复「禁用该模块」的依赖，对应的构建目标已被注释/移除（不要静默保留）
- [ ] `$WORK_DIR/reports/user_decisions.txt` 与本次切换实际动作一致

---

## 失败回滚

任何切换步骤失败时，直接回滚后再排查，避免半切换状态污染源码树：

```bash
# Blade
git -C $PROJECT_ROOT checkout -- thirdparty/

# Bazel
[ -f WORKSPACE.x86_backup ] && cp WORKSPACE.x86_backup WORKSPACE

# CMake
rm -rf build/
git -C $PROJECT_ROOT/third_party/<回滚的子模块> checkout -

# 子模块/补丁回滚后，必要时重新 git submodule update --init
```

回滚后将失败原因记录到 `$WORK_DIR/reports/switch_failures.txt`，再回到阶段 B 重新分析。

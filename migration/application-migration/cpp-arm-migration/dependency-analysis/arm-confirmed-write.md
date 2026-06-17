# 写入 ARM 确认清单与执行真实切换

> 本文件是「查到分支 → 用户确认 → 切换并校验」闭环的写入端与切换端，描述阶段 C 中的两个连续动作：
> 1. **阶段 C 登记与确认**：用户确认某依赖的 ARM 适配分支后，按**依赖库**将其登记到 [arm_confirmed.md](../arm_confirmed.md)（仅写清单文件），再就每个待切换依赖**逐项经用户确认**
> 2. **阶段 C 末尾切换**：确认通过后，立即把构建配置里这些依赖的分支 / commit / URL 替换为清单记录的 ARM 版本，并做基础校验，让项目在进入阶段 D（DevKit 扫描）前就已是 ARM 版本
>
> 切换放在阶段 C 末尾（而非阶段 D）的原因：用户刚确认完、信息最全时顺手切掉，避免拖到阶段 D 与源码适配交织；阶段 D 因此可专注 DevKit 扫描与源码修改。
>
> `arm_confirmed.md` 按**依赖库**索引，每个依赖库下用「项目当前引用的版本」作为匹配键。同一仓库不同项目引用不同分支时有多条记录并存。**不记录全局编译配置**（ABI/工具链/构建命令是主仓级约束，不属于本清单）。

> ⚠️ **顺序约束**：登记可逆（仅改一个清单文件），必须在用户通过 `AskUserQuestion` 明确确认后才执行；切换会修改项目源码树，必须在登记后、用户逐项确认切换后立即执行，并在进入阶段 D 前完成校验。把切换前置到阶段 C 末尾，是为了在用户信息最全时一次性落地，避免与阶段 D 的源码适配交织。

---

## 阶段 C：写入 ARM 确认清单

> **输入来源有两条**，写入方式相同：
> - 阶段 B 通过 [common-arm-probe.md](common-arm-probe.md) Section 5 **命中清单**的依赖（已知 ARM 适配，无需再问用户）——这些其实在阶段 B 就已查到，阶段 C 只需补登尚未在清单里、但用户刚确认的新依赖
> - 阶段 C 通过 `AskUserQuestion` 让用户**新确认**的依赖（清单里没有、探测后由用户提供 ARM 分支/包路径）

### 步骤 1：定位依赖库区块

打开 [arm_confirmed.md](../arm_confirmed.md)，按**依赖库名**查找区块。区块标题格式：

```markdown
## <依赖库名>
```

**若已存在**：定位到该区块表格末尾，准备追加行。注意同一依赖库下可能已有其他项目/其他版本的记录，**不要覆盖**，只追加。

**若不存在**：在文件末尾「已确认依赖记录」下追加一个新区块，使用统一表头（不区分构建系统）：

```markdown
## <依赖库名>

| 项目引用版本 (x86) | ARM 适配分支/commit | ARM URL/路径 | 来源项目 | 备注 |
|--------|--------|--------|--------|--------|
```

### 步骤 2：写入一条记录

按依赖类型填写一行：

| 依赖类型 | 项目引用版本 (x86) | ARM 适配分支/commit | ARM URL/路径 |
|---------|------------------|--------------------|--------------|
| git 类（submodule / `git_repository` / FetchContent GIT） | 项目当前引用的 commit/tag/分支 | 探测到的 ARM 分支名 + commit | `—`（除非 ARM 版换了 URL） |
| 预编译包（http_archive / Blade prebuilt / 脚本下载） | 包版本号或原下载地址 | `—` | ARM 版下载地址或库路径 |
| 用户提供本地 ARM 包 | 项目当前引用版本 | `—` | 用户提供的本地路径 |

- **来源项目**：填当前主仓名，便于溯源
- **备注**：特殊操作说明，如「需先注释自动签出」「ABI=0」「来自 thirdparty_arm 回迁」等；无则填 `—`

> 匹配键是「项目引用版本 (x86)」——后续其他项目迁移时，按它当前引用的版本到此行匹配。务必填准项目**当前实际引用**的 commit/tag/分支，而非 ARM 分支名。

### 步骤 3：仅对当前确认项追加行

每条确认结果对应**一行追加**，不要批量改写已有行。已有行是历史迁移成果，覆盖会丢失上下文。

### 步骤 4：在 user_decisions.txt 中同步留痕

阶段 C 收到用户的每条确认/否决都应记录到 `$WORK_DIR/reports/user_decisions.txt`，便于阶段 D/E 回溯：

```
[<时间戳>] <依赖名> → 已确认 ARM 适配，arm_confirmed.md 已追加（ARM 分支：<分支>）
[<时间戳>] <依赖名> → 用户选择「禁用该模块」
[<时间戳>] <依赖名> → 用户提供本地 ARM 包路径：<路径>
```

---

### 步骤 5：确认后切换分支并校验（阶段 C 末尾）

> 登记完成后**立即**在阶段 C 末尾完成切换，不要拖到阶段 D。原因：用户刚确认完、信息最全，此刻一次性把分支切到 ARM 版，阶段 D 即可专注 DevKit 扫描与源码适配。

#### 待切换清单汇总

切换前，把两类依赖合并成一份「待切换清单」：

| 来源 | 依赖的 ARM 适配信息从哪取 |
|------|------------------------|
| 阶段 B 命中 [arm_confirmed.md](../arm_confirmed.md)（common-arm-probe.md Section 5） | 清单匹配行记下的 ARM 分支/commit/URL/备注 |
| 阶段 C 新登记 | 刚写入清单的行 |

#### 🚨 切换前必须用户确认（不可跳过）

> **为什么必须确认**：同一个仓库可能存在多个 ARM 分支（如 `arm64` / `arm64-v2`），且不同项目引用版本对应的 ARM 分支不同。一旦切错分支，编译错误会在「x86 残留」和「找不到 ARM 符号」之间反复横跳，极难定位，迁移成本陡增。因此**任何依赖的分支/commit/URL 切换，都必须先经用户确认，不得自动执行**。

执行任何切换命令前，**必须调用 `AskUserQuestion`**，把待切换清单整理成一个确认清单，逐项让用户拍板。每个待切换依赖 = 一个 question：

```
question: "<依赖名> 当前引用 <项目当前版本>，清单记录的 ARM 适配为 <ARM 分支/commit>，是否切换？"
options:
  - "✅ 确认切换到 <ARM 分支/commit>"
  - "⏸ 我要先核对，暂不切换该依赖"
  - "❌ 不切换（保持现状）"
```

- 用户选「确认切换」→ 执行下面对应构建系统的切换命令
- 用户选「暂不切换 / 保持现状」→ 该依赖**不切换**，记录到 `$WORK_DIR/reports/user_decisions.txt`，编译时若因此报错再回头处理
- 用户可在确认时修正 ARM 分支名（若他掌握更准确的分支）→ 按用户修正值切换，并回写清单该行

> ⛔ **未获得用户逐项确认前，不得执行任何切换命令。** 这是阶段 C 的硬门控。

确认全部完成后，对每个「确认切换」的依赖，按其构建系统执行下面对应的切换命令。**切换前先完成「备注」列里的前置操作**（如 CMake 注释自动签出）。

#### Blade 项目：thirdparty_arm 回迁

Blade 项目通常将 ARM 库放在 `thirdparty_arm/` 下统一管理，构建前必须回迁到 `thirdparty/` 对应位置（因为 Blade 只识别 `thirdparty/`），同时切换 BUILD 文件到 ARM 版。

```bash
# 1. 备份当前 thirdparty 状态（便于失败回滚）
cd $PROJECT_ROOT
git -C $PROJECT_ROOT status thirdparty/ > $WORK_DIR/reports/blade_thirdparty_before.txt

# 2. 对待替换清单中每个 Blade 预编译库依赖执行回迁
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

# 3. 把待替换清单中 git 类依赖切到清单记录的 ARM 分支
#    ARM_BRANCH 取自清单该依赖匹配行的「ARM 适配分支/commit」
#    注意：同一仓库不同版本可能对应不同 ARM 分支（arm64 / arm64-v2 …），按清单记录填，不要写死
#    示例：依赖名 = my-internal-lib，ARM 分支 = arm64
ARM_BRANCH=<取自清单记录>
DEP_DIR=$(bazel info output_base 2>/dev/null)/external/my_internal_lib
if [ -d "$DEP_DIR" ]; then
    git -C "$DEP_DIR" fetch origin "$ARM_BRANCH"
    git -C "$DEP_DIR" checkout "$ARM_BRANCH"
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

# 3. 把待替换清单中 git 类子模块切到清单记录的 ARM 分支
#    ARM_BRANCH 取自清单该依赖匹配行的「ARM 适配分支/commit」
#    注意：同一仓库不同版本可能对应不同 ARM 分支（arm64 / arm64-v2 …），按清单记录填，不要写死
#    示例：third_party/foo → arm64
ARM_BRANCH=<取自清单记录>
git -C $PROJECT_ROOT/third_party/foo fetch origin "$ARM_BRANCH"
git -C $PROJECT_ROOT/third_party/foo checkout "$ARM_BRANCH"

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

#### 切换后校验（一句话提醒）

> ⚠️ 切换完别忘了校验：每个依赖是否真切到了清单记录的 ARM 分支/路径——切错或没切上，后续编译错误会极难排查。逐项核对下方清单后再进入阶段 D。

进入阶段 D（DevKit 扫描）前，先做完以下基础校验，避免把简单的路径/分支错误带进扫描与编译：

- [ ] 待切换清单中每个依赖，对应的 ARM 分支/路径/URL 在项目里**确实存在**（git 类依赖确认清单记录的分支能 `git fetch` 到）
- [ ] Blade：`thirdparty/<组件>/` 下能找到 `lib*.so` 且 `file lib*.so` 输出含 `aarch64`
- [ ] Bazel：`WORKSPACE` 当前内容来自 `WORKSPACE_arm`（`diff WORKSPACE WORKSPACE_arm` 应无差异）
- [ ] CMake：`rm -rf build/` 已执行；🚨 自动签出逻辑已注释/参数化（在 user_decisions.txt 留痕）；切换分支后 `git branch --show-current` 验证子模块分支未被重置
- [ ] 对阶段 C 中用户回复「禁用该模块」的依赖，对应的构建目标已被注释/移除（不要静默保留）
- [ ] `$WORK_DIR/reports/user_decisions.txt` 与本次切换实际动作一致

校验通过后，阶段 C 结束，进入阶段 D（DevKit 扫描，见 [sourcecode-devkit-scan.md](../sourcecode-devkit-scan.md)）。

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

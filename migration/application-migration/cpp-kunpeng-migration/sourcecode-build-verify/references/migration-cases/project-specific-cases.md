# 项目特有案例库（P 系列）— 脱敏样例

> 仅保留 P-01 一条案例作为格式参考。

| ID | 起始行 | 摘要 |
|----|--------|------|
| P-01 | 7 | ARM 部署流水线适配 |

---

### P-01：ARM 部署流水线适配（manifest、脚本、so 库路径）

**错误现象：**
```
运行时错误：部署到 ARM 机器后找不到动态库
./<可执行文件>: error while loading shared libraries: lib<库名>.so: cannot open shared object file
```

**根因分析：**
项目部署流水线（manifest 文件、部署脚本、so 库打包路径）仅适配了 x86 路径。ARM 环境下需要：1) manifest 中添加 ARM 依赖声明；2) 部署脚本中添加架构检测和 ARM so 库路径；3) 将 ARM 版 so 库打包到正确位置。

**修复方法：**

修改前：
```yaml
# manifest 中仅有 x86 so 库
- <x86-so-目录>/*.so
```

修改后：
```yaml
# manifest 中添加 ARM so 库
- <x86-so-目录>/*.so
- <arm-so-目录>/*.so
```

**适用场景：**
项目部署流水线需要同时支持 x86 和 ARM 架构

**验证方式：**
```bash
ldd <可执行文件> | grep "not found"
# 应无输出
```

**扫描规则：**
（P 系列不填写扫描规则）

---

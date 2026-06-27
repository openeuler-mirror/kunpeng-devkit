---
name: app-transform
summary: 对 Java 应用进行数据库兼容性和配置改造；有源码时修改编译，无源码时经授权后用 CFR 反编译改造重打包。
description: |
  当应用包、源码候选和迁移路线确认后调用。该子 Skill 负责 SQL 方言转换、JDBC Driver 替换、配置修改、源码编译、无源码反编译和重打包。
---

# app-transform 子 Skill

## 有源码路径

1. 确认源码路径和构建产物。
2. 识别 Maven/Gradle/Ant/自定义构建脚本。
3. 扫描配置：`application.yml`、`application.properties`、`jdbc.properties`、`bootstrap.yml` 等。
4. 替换 JDBC Driver 和连接串。
5. 扫描 SQL：MyBatis XML、SQL 文件、注解 SQL、JPA/Hibernate 方言。
6. 按目标 DM 兼容路线改造 SQL。
7. 编译打包。
8. 保存 diff、构建日志、产物 SHA256。

## 无源码路径

1. 要求用户确认反编译授权。
2. 备份原始 Jar/WAR/EAR。
3. 默认使用 CFR。
4. 解包并保留 Manifest、资源文件、lib 目录结构。
5. 优先改配置、XML、SQL、JDBC Driver。
6. 必要时修改 Java 逻辑。
7. 检测签名文件：`META-INF/*.SF`、`*.RSA`、`*.DSA`，提示签名失效风险。
8. 重新打包。

## 模型使用

- 默认 `agent-native`。
- `openai-compatible` 或外部模型时，源码/配置/SQL 发送前必须有用户确认。
- 模型输出不得直接覆盖文件，必须先生成 patch/diff，再由脚本应用和校验。

## 修复限制

- 同阶段最多 5 轮。
- 同一错误指纹连续出现 3 次停止。
- 全流程自动修复总轮次最多 10 轮。

## 输出

```json
{
  "phase": "app-transform",
  "status": "success",
  "source_mode": "source | no-source",
  "modified_files": [],
  "patches": [],
  "build_artifact": "",
  "risks": []
}
```

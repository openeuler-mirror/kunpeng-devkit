---
name: scan-analysis
summary: 解析 devkit_disk_scan.sh 产物，识别实际运行应用包、部署结构、中间件、数据库和源码候选。
description: |
  当源端扫描完成后调用。该子 Skill 读取 components.json、files_map.json、java_runtime.json、specified_pack.json，基于运行时信息优先判断实际使用 Jar/WAR/EAR，归纳部署结构，查找源码路径候选，并输出置信度和需要用户补充确认的信息。
---

# scan-analysis 子 Skill

## 判断实际应用包

优先级：

1. 运行中 Java 进程直接关联。
2. Tomcat/Resin 运行配置关联。
3. Webapps 或 web-app root-directory 关联。
4. 文件更新时间、路径名称、包名特征关联。

规则：

- `entry_type=Jar`：`main_jar` 为主启动 Jar，置信度高。
- `java -cp/-classpath`：解析 `runtime_class_path` 和 `sun_java_command`，主类为启动入口，classpath 中存在的 Jar 为真实依赖。
- Tomcat：结合 `-Dcatalina.home`、`-Dcatalina.base`、`runtime_conf`、`webapps`、`server.xml` 判断部署应用。
- Resin：结合 `-Dresin.home`、`-Dresin.root`、`-conf`、`resin.xml` 的 `<web-app root-directory="...">` 判断部署应用。
- 多候选包必须输出排序和置信度，不得强行只给一个结论。

## 部署结构分析

输出以下内容：

- Java Runtime/JDK 路径。
- 中间件类型、版本、home/base/root。
- 应用部署目录。
- 配置目录和关键配置文件。
- 日志目录、数据目录、启动脚本目录，如果可推断。
- 组件包和运行配置包位置。
- 运行中组件和磁盘存在但未运行组件。

## 源码路径识别

查找特征：

- `.git`
- `pom.xml`
- `build.gradle`
- `settings.gradle`
- `src/main/java`
- `src/main/resources`
- `Dockerfile`
- `Jenkinsfile`

关联规则：

1. Maven：通过 `artifactId`、`version`、`finalName`、模块名与 Jar/WAR/EAR 文件名关联。
2. Gradle：通过 project name、archivesBaseName、version 与应用包关联。
3. Manifest：通过 `Implementation-Title`、`Implementation-Version`、`Main-Class` 辅助关联。
4. 多模块工程必须标注模块路径和置信度。

不可可靠判断时必须输出候选和问题：

- 源码路径在哪里？
- 构建产物是哪个 Jar/WAR/EAR？
- 是否有多模块工程？
- 当前部署包是否由该源码构建？

## 输出

```json
{
  "phase": "scan-analysis",
  "status": "success",
  "runtime_apps": [],
  "deployment_topology": {},
  "source_candidates": [],
  "package_candidates": [],
  "manual_confirm_items": [],
  "confidence_summary": {}
}
```

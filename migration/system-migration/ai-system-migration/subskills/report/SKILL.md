---
name: report
summary: 生成迁移最终 Markdown 报告、JSON 报告、JSONL 执行日志摘要、风险项和人工确认项。
description: |
  当任意阶段完成或失败时均可调用。该子 Skill 汇总扫描、路线、凭据状态、中间件、数据库、应用改造、部署验证、失败项和人工建议，输出客户可读 Markdown 和工程 JSON。
---

# report 子 Skill

## 输出文件

- `migration-report.md`
- `migration-report.json`
- `execution-log.jsonl`
- `route-plan.yaml`
- `scan-summary.json`
- `risk-items.json`
- `manual-confirm-items.json`

## Markdown 报告结构

1. 迁移结论。
2. 源端扫描范围。
3. 应用部署结构。
4. 运行中组件清单。
5. 磁盘存在但未运行组件清单。
6. Java 进程与 Jar/WAR/EAR 关联关系。
7. 源码路径识别结果。
8. 迁移路线。
9. 中间件迁移结果。
10. 数据库迁移结果。
11. 应用改造结果。
12. 启动验证结果。
13. 失败项。
14. 人工确认项。
15. 安装包来源、版本、SHA256。
16. 配置修改清单。
17. 回滚建议。
18. 下一步建议。

## 脱敏规则

以下内容必须脱敏：

- password
- passwd
- pwd
- token
- api_key
- secret
- jdbc password
- 数据库连接串中的密码
- SSH 密码

## 输出 JSON 基本结构

```json
{
  "summary": {},
  "source_scan": {},
  "scan_analysis": {},
  "route_plan": {},
  "middleware": {},
  "database": {},
  "application_transform": {},
  "deploy_verify": {},
  "risks": [],
  "manual_confirm_items": [],
  "artifacts": []
}
```

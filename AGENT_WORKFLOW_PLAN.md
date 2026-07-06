# ClipFlow 三代理工作体系 — 最终创建方案

> 创建时间：2026-07-06
> 状态：已执行

---

## 文件一：`.claude/agents/coder.md`

- 名称：coder
- 职责：全链路业务代码开发 + 单元测试编写
- 工具：Read、Write、Edit、Bash、Glob、Grep（禁止 Agent、Workflow）
- 核心约束：加密方案/账户体系/Token持久化/数据库/技术栈不可更改

## 文件二：`.claude/agents/tester.md`

- 名称：tester
- 职责：全量测试验证，输出结构化测试报告
- 工具：Read、Bash、Glob、Grep（禁止 Write、Edit、Agent、Workflow）
- 测试项：flutter analyze + flutter test + 核心场景验证

## 文件三：`.claude/agents/reviewer.md`

- 名称：reviewer
- 职责：终审验收，判定通过/不通过，输出整改清单
- 工具：Read、Bash、Glob、Grep（禁止 Write、Edit、Agent、Workflow）
- 校验项：数据流完整性、边界异常覆盖、测试用例完整性、无局部修复遗漏

## CLAUDE.md 追加内容

- 三代理强制工作流规则
- 整改循环最多 3 轮，超限自动终止上报人工
- 工具约束与校验规则
- 交付规范（精简汇总，禁止粘贴原始日志）
- 子代理规则边界（仅加载自身 .md，不依赖 CLAUDE.md）

## 分场景触发规则

| 场景 | 处理方式 |
|------|---------|
| 轻量改动（注释、文案、配置、文档） | 主代理直接处理 |
| 普通功能新增 / Bug 修复 | 标准三代理流程 |
| 核心重大改动 | 完整三代理流程，加严校验 |

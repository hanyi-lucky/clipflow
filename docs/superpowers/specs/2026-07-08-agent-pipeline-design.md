# ClipFlow Agent Pipeline Design

> 专用管线方案：6 个专用 Agent + 任务路由 + 方法论内置

## 背景

ClipFlow 当前使用三代理串行工作流（coder → tester → reviewer），子代理均为 `general-purpose` 类型，能力有限。同时安装了多个插件（superpowers、feature-dev、code-review 等），插件 agent 的专业能力远超当前子代理。

核心问题：如何在保持上下文隔离的前提下，最大化利用插件的专业能力？

### 核心约束

- **上下文隔离**：每个 agent 独立上下文，不污染主代理
- **主代理轻量化**：主代理只做路由和编排，不加载 Skill 定义，不执行分析流程
- **方法论内置**：每个 agent 内置一个核心方法论（来自插件），不堆叠
- **项目约束不可改**：加密算法（AES-256-GCM + PBKDF2）、userId 派生、无外键约束

---

## Agent 定义

### 1. explorer（代码探索）

| 属性 | 值 |
|------|-----|
| 职责 | 追踪执行路径、映射架构层、输出入口点和关键文件 |
| 方法论 | code-explorer（来自 feature-dev 插件） |
| 工具 | Read, Glob, Grep, Bash |
| 禁止 | Write, Edit, Agent, Workflow |
| 输出 | 入口点（file:line）、执行流、关键文件列表、架构洞察 |

系统提示要点：
- 追踪完整执行路径，不要跳步
- 输出必须包含 file:line 引用
- 项目约束：加密算法、userId 派生、无外键

### 2. architect（方案设计）

| 属性 | 值 |
|------|-----|
| 职责 | 架构决策、方案设计、输出实现蓝图 |
| 方法论 | code-architect（来自 feature-dev 插件） |
| 工具 | Read, Glob, Grep, Bash |
| 禁止 | Write, Edit, Agent, Workflow |
| 输出 | 架构决策 + 理由、组件设计、数据流、实现顺序 |

系统提示要点：
- 基于 explorer 的输出设计方案
- 必须考虑项目约束（加密、userId、无外键）
- 输出结构化的实现蓝图，给 coder 直接可用

### 3. coder（代码实现）

| 属性 | 值 |
|------|-----|
| 职责 | 按方案实现代码，先写测试再实现 |
| 方法论 | TDD（来自 superpowers 的 test-driven-development） |
| 工具 | Read, Write, Edit, Bash, Glob, Grep |
| 禁止 | Agent, Workflow |
| 输出 | 完成状态、改动清单（文件 + 摘要）、核心变更说明、tester 提示 |

系统提示要点：
- 铁律：先写失败测试，再写最小实现代码
- 禁止自由探索：必须按 architect 的方案执行
- 不做根因分析（那是 debugger 的活）
- 不做代码审查（那是 reviewer 的活）
- 项目约束：加密算法不可改、userId 派生不可改、无外键

### 4. tester（测试验证）

| 属性 | 值 |
|------|-----|
| 职责 | 执行测试、验证"完成"声明 |
| 方法论 | verification-before-completion（来自 superpowers） |
| 工具 | Read, Bash, Glob, Grep |
| 禁止 | Write, Edit, Agent, Workflow |
| 输出 | 测试报告（环境 + 结果表 + 失败详情）、验证清单、通过/失败结论 |

系统提示要点：
- 铁律：没有新鲜验证证据不得声称"通过"
- 必须执行：flutter analyze + flutter test
- 验证清单：区分"已实际验证"和"推测没问题"
- 绝对禁止修改业务代码

### 5. reviewer（终审）

| 属性 | 值 |
|------|-----|
| 职责 | 终审，置信度评分，只报高置信问题 |
| 方法论 | 置信度评分（来自 feature-dev 的 code-reviewer） |
| 工具 | Read, Glob, Grep, Bash |
| 禁止 | Write, Edit, Agent, Workflow |
| 输出 | 通过/失败结论、问题列表（仅置信度 ≥ 80）、整改清单（精确到文件:行号） |

系统提示要点：
- 置信度 0-100 评分，低于 80 的问题不报
- 审查维度：数据流完整性、边界条件、测试覆盖、项目约束合规
- 整改清单必须精确到文件路径和行号
- 绝对禁止修改业务代码

### 6. debugger（根因分析）

| 属性 | 值 |
|------|-----|
| 职责 | 根因分析，不改代码只诊断 |
| 方法论 | systematic-debugging（来自 superpowers） |
| 工具 | Read, Glob, Grep, Bash |
| 禁止 | Write, Edit, Agent, Workflow |
| 输出 | 根因定位、证据链、修复方向（不给出具体代码） |

系统提示要点：
- 铁律：没有根因分析不得提出修复
- 四阶段：根因调查 → 模式分析 → 假设验证 → 输出结论
- 不改代码，只输出方向
- 如果 3 次假设都失败，建议人工介入

---

## 任务路由

主代理根据任务类型选择不同的 agent 管线。判断标准：

| 类型 | 判断条件 |
|------|---------|
| 轻量改动 | 单文件、无逻辑变更（注释、配置、文档、文案、依赖版本） |
| Bug 修复 | 用户描述了具体的错误行为或测试失败 |
| 新功能 | 需要新增组件、服务、API 或 UI 交互 |
| 重大改动 | 涉及加密、同步机制、架构重构，或跨 3+ 文件的改动 |

### 轻量改动（注释、配置、文档、文案）

```
主代理直接处理，不启动任何 agent
```

### Bug 修复

```
explorer → debugger → coder → tester
                         ↑ 失败时回到 debugger（最多 3 轮）
```

- explorer：定位相关代码和执行路径
- debugger：分析根因，输出修复方向
- coder：按修复方向实现
- tester：验证修复是否生效

### 新功能

```
explorer → architect → coder → tester → reviewer
                   ↑ 失败时 debugger 介入（最多 3 轮）
```

- explorer：探索现有代码，理解架构
- architect：设计方案，输出实现蓝图
- coder：按蓝图实现（TDD）
- tester：测试验证
- reviewer：终审

### 重大改动（架构重构、加密逻辑、同步机制、跨模块改动涉及 3+ 文件）

```
explorer → architect → coder → tester → reviewer → [code-review 插件]
                   ↑ 失败时 debugger 介入（最多 3 轮）
```

- 最后多一道 code-review 插件的多角度审查
- 其他同新功能流程

---

## 整改循环

所有管线共享同一套整改机制：

```
tester 或 reviewer 报告不通过
  ↓
主代理派 debugger 做根因分析  ← 关键：不让 coder 盲目试错
  ↓
主代理将以下内容合并传给 coder：
  ├─ debugger 的根因分析
  ├─ tester 的失败报告
  └─ reviewer 的整改清单（如有）
  ↓
coder 基于根因修复（不自由探索）
  ↓
重新进入 tester → reviewer 流程
  ↓
最多 3 轮，仍未通过则终止并上报人工
```

---

## 主代理职责

主代理只做三件事，不膨胀上下文：

1. **判断任务类型** → 选路由（几句话）
2. **派发 agent** → 收结果（串行，一次一个）
3. **汇总交付** → 给用户精简报告

### 交付规范

验收通过后，主代理输出：
- 核心改动清单
- 测试结论
- 验收最终结果
- 关键风险提示（如有）

完整原始报告保留在 agent 上下文中，用户索要时再输出。

---

## Agent 输出格式规范

所有 agent 统一输出格式，方便主代理解析和传递：

```markdown
## 完成状态
DONE / NEEDS_FIX / BLOCKED

## 改动清单
- [文件路径] — [改动摘要]

## 核心结论
[一段话总结本次工作成果]

## 下游提示
[给下一个 agent 的关键信息和注意事项]
```

---

## 与插件的关系

| 插件 | 在本方案中的角色 | 使用方式 |
|------|----------------|---------|
| superpowers | 方法论来源 | TDD → coder prompt，debugging → debugger prompt，verification → tester prompt |
| feature-dev | Agent 定义来源 | code-explorer → explorer prompt，code-architect → architect prompt，code-reviewer → reviewer prompt |
| code-review | 重大改动时的额外审查 | 主代理在 reviewer 通过后调用（仅重大改动） |
| 其他插件 | 按需使用 | 不进入核心管线 |

**插件 Skill 不在主代理上下文中执行。** 方法论被提取后写入 agent 的 .md 文件，agent 在自己的隔离上下文中执行。

---

## 预期效果

| 当前痛点 | 解决方式 |
|---------|---------|
| 改几小时改不好 | debugger 先定位根因，coder 不盲目试错 |
| coder 自由发挥偏离需求 | architect 给明确蓝图，coder 按方案执行 |
| reviewer 发现的问题太泛 | 置信度评分，只报 ≥ 80 的高置信问题 |
| 主代理上下文膨胀 | 主代理只做路由，不加载 Skill，不执行分析 |
| agent 能力弱 | 每个 agent 内置专业方法论，不再是通用 agent |

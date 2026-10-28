# 012 · Phase 1A：outbox 文件名安全化与迁移

- 日期：2026-10-28
- 状态：Phase 1A 已实现，Windows 真机验收待完成
- 档位/组合：完整（architect 冻结 → coder TDD → tester / reviewer 待接力）

## 背景

云端 durable outbox 的 `SyncOperation.operationId` 会使用 `del:<entryId>` /
`rest:<entryId>` 这类逻辑标识。原实现直接将其拼为
`<operationId>.json`，冒号在 Windows 是非法文件名字符，可能导致写入失败、
意外 ADS 或重启后无法重放。

Phase 1A 只处理存储层文件名安全化、旧文件迁移与删除兼容；不修改
`SyncOperation` schema、outbox interface、coordinator、同步协议、服务端、
LAN、加密、userId 派生或 token 持久化。

## 决策

1. **canonical 文件名**
   - `v2-<sha256(utf8(operationId)) lowercase hex>.json`
   - operationId 原样保存在 manifest 内容中；不得从文件名反解 opId。
2. **原子写**
   - 同一目录创建唯一 `.tmp`，写满并 flush 后直接 `temp.rename(canonical)`。
   - 禁止先删除 target；`put` / `update` 均走同一路径。
   - 构造器可注入 `rename` hook 用于故障测试，生产默认 `File.rename`。
3. **loadActive 识别与优先级**
   - 以 manifest 内容中的 `operationId` / `userId` 识别身份。
   - 同一 opId 的有效副本优先级：canonical > legacy 普通文件 > temp。
   - legacy 包含旧 UUID 文件名及通用旧文件名；`del:` / `rest:` 仅存在于
     manifest 内容，文件名不可作为身份来源。
   - 双份记录只返回一次；temp-only 可从 `.tmp` 恢复（at-least-once）。
4. **迁移完整性**
   - 优先将 legacy/temp 提升为 canonical，并回读验证 opId 后才删除源。
   - rename、读写或其他 I/O 错误不删源；仅 JSON/schema 损坏可清理。
   - sending 状态在 load 时转回 pending，并写回 canonical。
5. **hash 路径冲突保护**
   - 若目标 canonical 文件属于另一个合法 opId，不得覆盖或误删。
   - 两个操作都返回，原 canonical 保持不动；冲突组的 legacy 副本保留。
   - 任何 non-target canonical-shaped 文件（文件名符合 canonical 格式，但
     不是该 manifest 内容 operationId 对应的目标路径）都是持久占用者：
     `loadActive` 不得删除、迁移或覆盖它，即使其 manifest 内容与另一个
     exact canonical 的 opId 相同。
   - “canonical > legacy > temp”只描述同一 opId 的副本选择优先级，不表示
     可以清理所有非选中副本。普通 legacy 与 valid temp 可清理；non-target
     canonical-shaped 永远不走该清理路径。
   - 同一 opId 同时存在 exact canonical、同内容的 misplaced
     canonical-shaped、普通 legacy 与 valid temp 时：返回 exact canonical
     一次，exact canonical 字节保持不变；普通 legacy/temp 被清理；
     misplaced canonical-shaped 字节与其占用路径持续保留。反向创建顺序
     结果相同，连续两次 `loadActive` 也保持幂等。
   - 若 exact canonical 不存在而只有 misplaced canonical-shaped，仍按
     manifest 内容 identity 返回该 operation；该文件继续占用其原文件名
     对应的目标路径，不迁移。
6. **remove**
   - 按 manifest 内容匹配 operationId，兼容 canonical、legacy、temp。
   - 先删除所有非 canonical 副本，最后删除 canonical；任一前置删除失败
     不删除最后权威副本。
7. **clearUser**
   - 收集目录内 matching userId 的 `artifactId` 并去重，然后删除整个用户
     目录；其他用户目录不受影响。
   - 不在本次新增原生 ADS 枚举；若 Windows 真机验证发现 ADS-only 文件，
     必须在验收报告明确残余风险。

## 后果

- 文件名不再包含 `:`，路径满足 Windows 常规文件约束。
- 旧 UUID / `del:` / `rest:` manifest 可在升级后加载、迁移、删除并且不重复入队。
- 迁移中断时源文件保留，下一次 `loadActive` 可重试；at-least-once 语义保留。
- 协议层 operationId 保持原样，`del:<entryId>` / `rest:<entryId>` 不变。
- 本工作树仅完成 LOCAL_GREEN；Windows 真机 `put → restart → load → remove`、
  非法文件名/ADS 检查仍为 `WINDOWS_VERIFICATION_PENDING`，不得据此宣称
  Phase 1A 整体完成。

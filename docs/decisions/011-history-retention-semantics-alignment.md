# 011 · history 保留语义对齐：置顶不占名额、垃圾箱不参与裁剪

- 日期：2026-09-04
- 来源：全项目交付后审查（docs/project-review-prompt.md 工作流）P1 发现 ×2
- 档位/组合：标准（审查 → architect → coder → tester → reviewer → /code-review）

## 背景

审查发现服务器 history 100 条裁剪 SQL（`server/index.js` 两处：上传后裁剪 + 文件元数据事务内裁剪）为：

```sql
DELETE FROM history WHERE user_id = ? AND id NOT IN (
  SELECT id FROM history WHERE user_id = ? ORDER BY timestamp DESC LIMIT 100
)
```

存在两个缺陷：
1. 无 pinned 过滤——置顶条目时间戳跌出最新 100 条后被静默删除（客户端本地 `_trim()` 有保护，实际影响 = 重装/换设备后置顶丢失）
2. 无 deleted_at 过滤——垃圾箱软删条目占用 100 条名额，活跃条目被挤出消失

同批修复：`DELETE /api/device/:id` 踢 token 补 `user_id` 过滤（防御纵深）；`index.js` HOST 默认 `0.0.0.0` → `127.0.0.1`（不安全默认）。

## 决策

**裁剪语义与客户端 `HistoryService._trim()` 完全对齐：**

> 保留 = 最新 100 条**非置顶活跃**条目 + 全部**置顶活跃**条目；垃圾箱软删条目（`deleted_at IS NOT NULL`）**不参与裁剪、不占名额**（它们有自己的生命周期：手动倾倒或 24h 自动清理）。

置顶条目是否计入 100 名额的取舍：**不计入**。理由——客户端 `_trim()`（`_entries.where((e) => !e.isPinned).length > maxEntries`）已采用「非置顶计数」语义，服务器对齐可避免两端行为分裂；若置顶计入名额，用户置顶 20 条后实际可保留的普通历史只剩 80 条，与客户端展示不一致。

**historyLimit（10-100）接线语义：** 设置只作用于客户端本地截断；服务器 100 条为硬顶（客户端 >100 被 clamp 不可能）。客户端设置 <100 时，重装/换设备会先从服务器拉取最多 100 条再本地截断到设定值——属预期语义，不改服务器。

## 后果

- 两处裁剪 SQL 加 `deleted_at IS NULL AND pinned = 0`（外层 + 子查询），语义由 smoke 54/55/56 回归锁定
- token 删除、HOST 默认值属低风险加固，无语义变化
- 已部署生产（2026-09-04，md5 校验 + ping 验证通过）
- 行为变化提示：本地裸跑 `node index.js` 现在只绑回环，LAN 真机联调需显式 `HOST=0.0.0.0`

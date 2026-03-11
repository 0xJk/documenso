# 001 — Fix Prisma Transaction Timeout & Optimize Field Save Performance

## Context

Render 部署报 `P2028` 错误 — `set-fields-for-document.ts` 中的 Prisma 事务在 30s 超时。用户反馈即使升级 Render Standard 也不丝滑。

### 第一性原理分析：为什么代码是这样写的？

Documenso 是为**低延迟 DB 部署**设计的：
- 自托管 (Docker Compose): DB 在同一机器，延迟 ~0ms
- Documenso Cloud: DB 在同一数据中心，延迟 <1ms
- 开发环境: 本地 PostgreSQL，延迟 ~0ms

在这些场景下，50 字段 × 2 ops × 0.5ms = **50ms**，完全没问题。upsert-all 模式是简单、正确、原子性好的设计，只要 DB 延迟足够低。

**我们遇到的问题不是代码 bug，而是部署拓扑问题：**
- 同一机器: 50ms (正常)
- 同一区域: 100ms (正常)
- **跨区域: 10s+ (崩溃)** ← 我们在这里

跨区域部署把原本可忽略的延迟放大了 100-200 倍，导致了超时和锁竞争。之前的"修复"（增加超时从 5s→30s→60s）本质是治标不治本。

**结论：迁移到同区域部署是根本解法（见 002 计划）。** 代码优化是锦上添花 — 即使不做，同区域部署也能正常工作。但做了之后会更快更健壮。

### 数据库日志分析

DB 日志显示单条 `UPDATE "Field"` 耗时 **21-29 秒**：
```
duration: 24903.488 ms  (client=10.19.143.36)
duration: 21540.418 ms  (client=10.16.67.228)
duration: 29034.123 ms  (client=10.19.143.36)
```

按主键 UPDATE 一行应该 <1ms。**25 秒 = 行锁等待 (row lock contention)**。

两个 Render 实例 (`10.19.143.36`, `10.16.67.228`) 同时更新同一文档的 Field 记录：
```
0s   → 实例A: 事务开始，Promise.all 并发 upsert 全部 Field 行
0.1s → 实例B: 事务开始，UPDATE Field → 被实例A的行锁阻塞
25s  → 实例A 事务完成 → 实例B 的 UPDATE 才开始执行
27s  → 实例B 后续 UPDATE 碰到新锁 → 30s 超时!
```

### 问题链 (4层)

| 层级 | 问题 | 影响 |
|------|------|------|
| **基础设施层** | Web service 和 DB 不在同一 region | 每次 DB 往返 ~50-200ms（同区域 ~1ms） |
| **应用层** | 每次保存 upsert 全部字段（包括未变更的） | 事务持锁时间 = N × 单次往返延迟 |
| **事务层** | 显式 30s 超时 < 全局 60s 设置 | 本可以多等 30s 但被截断 |
| **并发层** | 多个 Render 实例同时编辑同一文档 | 行锁竞争，级联等待 |

**跨区域延迟 × 操作次数 = 灾难性放大**：
- 同区域 50 字段: 100 ops × 1ms = ~100ms
- 跨区域 50 字段: 100 ops × 100ms = ~10s（再加锁等待 = 25s+）

---

## Plan（代码优化，修改 1 个文件）

**File**: `packages/lib/server-only/field/set-fields-for-document.ts`

### Step 1: Remove explicit timeout override (line 317)

```diff
    },
-   { timeout: 30000 },
  );
```

移除后使用全局 60s 超时（`packages/prisma/index.ts:15-18`）。

### Step 2: Skip upserts for unchanged fields（最大性能提升）

在 Promise.all map 内，所有验证之后（line 222）、upsert 之前（line 224）插入：

```typescript
// Skip DB operations for unchanged fields
if (field._persisted && !hasFieldBeenChanged(field._persisted, field)) {
  return {
    ...field._persisted,
    formId: field.formId,
  };
}
```

**为什么安全（已验证）**:
- `hasFieldBeenChanged()` (line 388) 已存在，比较 position、dimensions、type、fieldMeta
- `field._persisted` 是完整的 `Field` 记录（来自 line 63 的 include）
- **返回值兼容性已验证**: `mapFieldToLegacyField()` (`packages/lib/utils/fields.ts:71-81`) 只访问 `Field` 标量属性和 `envelope.type`/`envelope.secondaryId`，不依赖 `recipient` 关联。虽然 `field._persisted` 包含 `recipient`（来自 include），但 upsert 返回值不包含 — 两者都能通过 `mapFieldToLegacyField()` 处理，行为一致。
- 新创建的字段没有 `_persisted`，不会被跳过
- 所有字段都未变更时，返回全部 `_persisted` 数据，`auditLogDataToCreate` 为空，`createMany` 被 `length > 0` 守护跳过

**效果**:
- DB 操作从 ~2N 降到 ~2C（C = 实际变更字段数，通常 1-2）
- 事务持锁时间从 N×往返 降到 C×往返
- 锁竞争自然消失

### Step 3: Batch audit logs with createMany

当前：每个字段单独 `await tx.documentAuditLog.create()`（lines 282-308）
改为：收集审计日志数据，事务内 Promise.all 完成后一次 `tx.documentAuditLog.createMany()`

具体改动：

1. 在事务回调开头声明收集数组：
```typescript
const auditLogDataToCreate: ReturnType<typeof createDocumentAuditLogData>[] = [];
```

2. 将 lines 282-308 的 `await tx.documentAuditLog.create({ data: ... })` 改为 `auditLogDataToCreate.push(...)`

3. Promise.all 之后、事务结束前，批量插入：
```typescript
if (auditLogDataToCreate.length > 0) {
  await tx.documentAuditLog.createMany({
    data: auditLogDataToCreate,
  });
}
```

4. 事务返回值从直接返回 `Promise.all` 结果，改为先执行 Promise.all，再执行 createMany，最后返回结果。

**复用模式**: 同文件 line 330 已有 `createMany` + `createDocumentAuditLogData` 的组合。

---

## Note: Other 30s timeout overrides

七个文件有显式 `{ timeout: 30_000 }` 早于全局 60s 设置。目前未报错但属于同类问题：
`resend-document.ts`, `create-team-email-verification.ts`, `accept-organisation-invitation.ts`, `resend-team-email-verification.ts`, `delete-team.ts`, `send-2fa-token-email.ts`, `link-organisation-account.ts`

## Key Files

- `packages/lib/server-only/field/set-fields-for-document.ts` — 唯一修改目标
- `packages/lib/utils/fields.ts:71-81` — `mapFieldToLegacyField()`（已验证不依赖 recipient）
- `packages/prisma/index.ts:15-18` — 全局事务超时配置
- `packages/lib/client-only/hooks/use-autosave.ts` — 前端自动保存（已有队列保护，无需修改）

## Verification

1. `npm run build` — 确保编译通过
2. 部署后测试：20+ 字段文档，拖动单个字段 → 应在 <1s 完成
3. 测试：多个浏览器 tab 同时编辑 → 不应再超时
4. Monitor DB logs — UPDATE duration 应从 25s 降到 <100ms
5. Monitor app logs — 不再有 P2028 错误
6. 验证审计日志正确性（变更/新增/删除的字段都有记录）

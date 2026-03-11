# 001 — 性能优化 + 迁移到 DigitalOcean

## Context

Render 部署报 `P2028` 超时错误，UI 不丝滑。根因：Web service 和 DB 跨区域部署（每次 DB 往返 ~100ms），叠加代码层面 upsert-all 模式（50 字段 = 100 次 DB 操作），再加上多实例行锁竞争，导致单条 UPDATE 耗时 25 秒。

### 第一性原理

Documenso 为低延迟 DB 部署设计（自托管/同区域），upsert-all 模式在 <1ms 延迟下只需 ~50ms。跨区域部署放大延迟 100 倍，不是代码 bug，是部署拓扑问题。

### DB 日志证据

```
duration: 24903.488 ms  UPDATE "Field" ...  (client=10.19.143.36)
duration: 21540.418 ms  UPDATE "Field" ...  (client=10.16.67.228)
```
25 秒 = 行锁等待。两个 Render 实例同时 upsert 同一文档的全部 Field。

---

## Part A: 代码优化（修改 1 个文件）

**File**: `packages/lib/server-only/field/set-fields-for-document.ts`

### A1. Remove explicit timeout override (line 317)

```diff
    },
-   { timeout: 30000 },
  );
```

移除后继承全局 60s 超时（`packages/prisma/index.ts:15-18`）。

### A2. Skip upserts for unchanged fields

在 Promise.all map 内，验证之后（line 222）、upsert 之前（line 224）插入：

```typescript
if (field._persisted && !hasFieldBeenChanged(field._persisted, field)) {
  return {
    ...field._persisted,
    formId: field.formId,
  };
}
```

**安全性已验证**:
- `hasFieldBeenChanged()` (line 388) 已存在，比较 position、dimensions、type、fieldMeta
- `mapFieldToLegacyField()` (`packages/lib/utils/fields.ts:71-81`) 不依赖 `recipient` 关联
- 新字段没有 `_persisted`，不会被跳过

**效果**: DB 操作从 ~2N 降到 ~2C（C = 变更字段数，通常 1-2）

### A3. Batch audit logs with createMany

1. 事务开头声明：
```typescript
const auditLogDataToCreate: ReturnType<typeof createDocumentAuditLogData>[] = [];
```

2. 将 lines 282-308 的 `await tx.documentAuditLog.create({ data: ... })` 改为 `auditLogDataToCreate.push(...)`

3. Promise.all 之后批量插入：
```typescript
if (auditLogDataToCreate.length > 0) {
  await tx.documentAuditLog.createMany({ data: auditLogDataToCreate });
}
```

复用同文件 line 330 的现有 `createMany` 模式。

---

## Part B: 迁移到 DigitalOcean

既然不需要保留 Render 数据，可以直接全新部署。

### B1. 创建 DigitalOcean Managed PostgreSQL

- Dashboard → Databases → Create Database Cluster
- Engine: PostgreSQL 16
- **Region: 与 App Platform 相同**（选离用户最近的区域）

### B2. 创建 App Platform 应用

| 设置 | 值 |
|------|-----|
| Source | GitHub repo |
| Source Directory | `/` |
| Build Command | `npm install && npm run build` |
| Run Command | `NODE_ENV=production npx turbo run start --filter=@documenso/remix` |
| HTTP Port | `3000` |
| Health Check | `/api/health` |
| Node Version | `22`（package.json 要求 >=22） |
| Instance Size | ≥1GB RAM |
| Region | **与数据库相同** |

> Run Command 使用 turbo 确保 CWD 在 `apps/remix/` 下，静态资源路径正确。turbo 会自动执行 `prisma migrate deploy` + `node build/server/main.js`。

### B3. 环境变量

**必需**:
```
NODE_ENV=production
NEXTAUTH_SECRET=<openssl rand -hex 32>
NEXT_PRIVATE_ENCRYPTION_KEY=<openssl rand -hex 16>
NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY=<openssl rand -hex 16>
NEXT_PUBLIC_WEBAPP_URL=https://your-domain.com
NEXT_PRIVATE_INTERNAL_WEBAPP_URL=http://localhost:3000
```

**数据库连接**:
```
# 池化连接（运行时）— 不要手动加 &pgbouncer=true
# packages/prisma/helper.ts 检测到两个 URL 不同时会自动添加
NEXT_PRIVATE_DATABASE_URL=postgresql://user:pass@db-host-pooler:25061/dbname?sslmode=require

# 直连（Prisma 迁移）
NEXT_PRIVATE_DIRECT_DATABASE_URL=postgresql://user:pass@db-host:25060/dbname?sslmode=require
```

> DO Managed DB 端口：25060（直连）、25061（连接池）。迁移用直连，运行时用池化。

**SMTP**:
```
NEXT_PRIVATE_SMTP_TRANSPORT=smtp-auth
NEXT_PRIVATE_SMTP_HOST=<smtp-host>
NEXT_PRIVATE_SMTP_PORT=587
NEXT_PRIVATE_SMTP_USERNAME=<username>
NEXT_PRIVATE_SMTP_PASSWORD=<password>
NEXT_PRIVATE_SMTP_FROM_NAME=Aline Docsign
NEXT_PRIVATE_SMTP_FROM_ADDRESS=noreply@yourdomain.com
```

**文件存储**（推荐 DO Spaces，S3 兼容）:
```
NEXT_PUBLIC_UPLOAD_TRANSPORT=s3
NEXT_PRIVATE_UPLOAD_ENDPOINT=https://sgp1.digitaloceanspaces.com
NEXT_PRIVATE_UPLOAD_FORCE_PATH_STYLE=true
NEXT_PRIVATE_UPLOAD_REGION=sgp1
NEXT_PRIVATE_UPLOAD_BUCKET=your-bucket
NEXT_PRIVATE_UPLOAD_ACCESS_KEY_ID=<key>
NEXT_PRIVATE_UPLOAD_SECRET_ACCESS_KEY=<secret>
```

**PDF 签名证书**:
```
NEXT_PRIVATE_SIGNING_TRANSPORT=local
NEXT_PRIVATE_SIGNING_LOCAL_FILE_CONTENTS=<base64-encoded-p12>
NEXT_PRIVATE_SIGNING_PASSPHRASE=<password>
```

### B4. 配置域名

- App Platform → Settings → Domains → Add Domain
- DNS 添加 CNAME 指向 DO 提供的 URL

### B5. 验证

- `https://your-domain.com/api/health` → status: ok
- 测试：创建文档 → 添加字段 → 签署 → 完成

---

## Key Files

- `packages/lib/server-only/field/set-fields-for-document.ts` — Part A 唯一修改目标
- `packages/lib/utils/fields.ts:71-81` — `mapFieldToLegacyField()`（已验证不依赖 recipient）
- `packages/prisma/index.ts:15-18` — 全局事务超时配置
- `packages/prisma/helper.ts` — 自动检测 pgbouncer

## Verification

1. `npm run build` — 编译通过
2. 部署到 DigitalOcean
3. 20+ 字段文档，拖动单个字段 → <1s 完成
4. 多 tab 同时编辑 → 无超时
5. 审计日志正确记录（变更/新增/删除）
6. DB logs — UPDATE duration <10ms

## 后续优化方向（不阻塞本次）

- 签署流程有 20-27 次 DB 往返（envelope 重复查询 3-4 次），同区域后 ~27ms 可接受
- `set-document-recipients.ts` 有类似的 upsert-all 问题
- 七个文件有残留的 `{ timeout: 30_000 }` 可清理

# 002 — 从 Render 迁移到 DigitalOcean (App Platform + Managed PostgreSQL)

## Context

当前 Render 部署的 Web service 和 PostgreSQL 不在同一 region，导致每次 DB 往返延迟 ~50-200ms。这是 001 计划中 P2028 超时和 UI 卡顿的根本原因（见 001 的第一性原理分析）。

本计划聚焦基础设施迁移。代码优化见 `plans/001_fix_field_transaction_timeout.md`。

### 为什么迁移到 DigitalOcean 而非修复 Render region

- Render 不支持直接更改已有数据库的 region，需要新建 + 数据迁移
- 既然要重建，不如迁移到 DigitalOcean App Platform（类似 PaaS 体验）
- DigitalOcean Managed PostgreSQL 有自动备份、故障转移、连接池

### 预期效果
- DB 往返延迟从 ~100ms 降到 ~1ms（100x 改善）
- 50 字段保存从 ~10s 降到 ~100ms（即使不做 001 的代码优化）
- 签署流程从 ~2s 降到 ~20ms

---

## 迁移步骤

### Step 1: 创建 DigitalOcean Managed PostgreSQL

- Dashboard → Databases → Create Database Cluster
- Engine: PostgreSQL 16
- **Region: 与后续 App Platform 相同的区域**（选离用户最近的）
- Plan: Basic 或 Professional（根据需要）
- 记录连接信息：host, port, username, password, database

### Step 2: 迁移数据（从 Render PostgreSQL）

```bash
# 1. 从 Render 导出
pg_dump -Fc --no-acl --no-owner \
  -h <RENDER_DB_HOST> -U <RENDER_DB_USER> -d <RENDER_DB_NAME> \
  > documenso_backup.dump

# 2. 导入到 DigitalOcean（注意 DO 默认端口 25060，强制 SSL）
PGPASSWORD=<DO_DB_PASSWORD> pg_restore --verbose --clean --no-acl --no-owner \
  -h <DO_DB_HOST> -p 25060 -U <DO_DB_USER> -d <DO_DB_NAME> \
  documenso_backup.dump
# 注意：DigitalOcean 默认强制 SSL，pg_restore 会自动使用 SSL 连接
# 如需显式指定：export PGSSLMODE=require
```

**数据迁移验证（必做）**:
```bash
# 3. 对比行数（在新旧 DB 上各执行一次）
psql -h <HOST> -U <USER> -d <DB> -c "
  SELECT 'Envelope' AS table_name, COUNT(*) FROM \"Envelope\"
  UNION ALL SELECT 'Field', COUNT(*) FROM \"Field\"
  UNION ALL SELECT 'Recipient', COUNT(*) FROM \"Recipient\"
  UNION ALL SELECT 'User', COUNT(*) FROM \"User\"
  UNION ALL SELECT 'Team', COUNT(*) FROM \"Team\";
"

# 4. 在新 DB 上运行 Prisma 迁移，确认 schema 版本对齐
npx prisma migrate deploy --schema packages/prisma/schema.prisma

# 5. 确认无 pending migrations
npx prisma migrate status --schema packages/prisma/schema.prisma
```

### Step 3: 创建 DigitalOcean App Platform 应用

- Dashboard → Apps → Create App
- Source: GitHub repo

**Component 配置**:

| 设置 | 值 |
|------|-----|
| Type | Web Service |
| Source Directory | `/` |
| Build Command | `npm install && npm run build` |
| Run Command | `NODE_ENV=production npx turbo run start --filter=@documenso/remix`（与 Render 一致，turbo 自动在 apps/remix/ 下执行 prisma migrate + node server，确保静态资源路径正确） |
| HTTP Port | `3000` |
| Health Check | `/api/health` |
| Node Version | `22`（package.json 要求 >=22，DO 默认版本更低，必须显式指定） |
| Instance Size | Basic 或 Professional (≥1GB RAM, 建议 2GB+) |
| Region | **与数据库相同** |

### Step 4: 配置环境变量

**必需变量**:
```
NODE_ENV=production
NEXTAUTH_SECRET=<必须从 Render 复制！重新生成会导致所有用户 session 失效>
NEXT_PRIVATE_ENCRYPTION_KEY=<必须从 Render 复制！否则加密数据无法解密>
NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY=<必须从 Render 复制>
NEXT_PUBLIC_WEBAPP_URL=https://your-domain.com
NEXT_PRIVATE_INTERNAL_WEBAPP_URL=http://localhost:3000
```

**数据库连接（注意连接池）**:
```
# 池化连接 — 用于应用运行时查询
# 注意：不要手动加 &pgbouncer=true，Prisma helper (packages/prisma/helper.ts)
# 会在检测到 DATABASE_URL 和 DIRECT_DATABASE_URL 不同时自动添加
NEXT_PRIVATE_DATABASE_URL=postgresql://user:pass@db-host-pooler:25061/dbname?sslmode=require

# 直连 — 用于 Prisma 迁移（迁移不能走连接池）
NEXT_PRIVATE_DIRECT_DATABASE_URL=postgresql://user:pass@db-host:25060/dbname?sslmode=require
```

> DigitalOcean Managed DB 提供两个端口：25060（直连）和 25061（连接池/PgBouncer）。
> Prisma 迁移必须用直连（25060），应用运行时建议用池化连接（25061）。
> `packages/prisma/helper.ts` 会自动检测两个 URL 不同并添加 `pgbouncer=true` 参数，无需手动添加。

**SMTP（从 Render 复制现有配置）**:
```
NEXT_PRIVATE_SMTP_TRANSPORT=smtp-auth
NEXT_PRIVATE_SMTP_HOST=<your-smtp-host>
NEXT_PRIVATE_SMTP_PORT=587
NEXT_PRIVATE_SMTP_USERNAME=<username>
NEXT_PRIVATE_SMTP_PASSWORD=<password>
NEXT_PRIVATE_SMTP_FROM_NAME=Aline Docsign
NEXT_PRIVATE_SMTP_FROM_ADDRESS=noreply@yourdomain.com
```

**文件存储**（推荐 DigitalOcean Spaces，S3 兼容）:
> 注意：切换到 S3 后，已有的数据库存储文档仍可正常读取。文件读取按每条记录的 `DocumentDataType` 分发（BYTES/S3_PATH），不依赖全局环境变量。
```
NEXT_PUBLIC_UPLOAD_TRANSPORT=s3
NEXT_PRIVATE_UPLOAD_ENDPOINT=https://sgp1.digitaloceanspaces.com
NEXT_PRIVATE_UPLOAD_FORCE_PATH_STYLE=true
NEXT_PRIVATE_UPLOAD_REGION=sgp1
NEXT_PRIVATE_UPLOAD_BUCKET=your-bucket-name
NEXT_PRIVATE_UPLOAD_ACCESS_KEY_ID=<spaces-key>
NEXT_PRIVATE_UPLOAD_SECRET_ACCESS_KEY=<spaces-secret>
```

**PDF 签名证书**:
```
NEXT_PRIVATE_SIGNING_TRANSPORT=local
NEXT_PRIVATE_SIGNING_LOCAL_FILE_CONTENTS=<base64-encoded-p12-cert>
NEXT_PRIVATE_SIGNING_PASSPHRASE=<cert-password>
```

### Step 5: 配置域名 + DNS 切换

1. App Platform → Settings → Domains → Add Domain
2. 在 DNS 提供商添加 CNAME 记录指向 App Platform 的 URL
3. **DNS TTL**: 切换前 24 小时将 TTL 降到 60s，确保快速生效

### Step 6: 验证 + 回滚窗口

1. 访问 `https://your-domain.com/api/health` 确认应用正常
2. 测试核心流程：文档创建 → 字段添加 → 签署 → 完成
3. 确认 DB 延迟正常（字段保存应在 <1s 完成）
4. **保留 Render 旧环境 24-48 小时**，确认一切正常后再关闭
5. 如有问题，DNS CNAME 切回 Render 即可回滚

---

## 风险与注意事项

| 风险 | 缓解措施 |
|------|----------|
| pg_dump 和切换之间的数据丢失 | 低流量时段操作，先暂停 Render 写入 |
| 加密密钥不一致导致数据无法解密 | 必须从 Render 复制 `ENCRYPTION_KEY` 和 `SECONDARY_KEY` |
| SSL 连接失败 | DigitalOcean 强制 SSL，连接串必须含 `sslmode=require` |
| 连接池模式不兼容 | Prisma 迁移用直连 25060，运行时用池化 25061 |
| 停机时间过长 | 先部署测试实例验证流程，再做正式切换 |

## 操作时间线（建议）

```
D-1:  降低 DNS TTL 到 60s
D-0:
  00:00  暂停 Render 服务（维护模式）
  00:05  pg_dump 从 Render 导出
  00:15  pg_restore 到 DigitalOcean
  00:25  验证数据行数 + prisma migrate status
  00:30  启动 DigitalOcean App Platform
  00:35  验证 /api/health + 核心流程测试
  00:40  切换 DNS CNAME
  00:45  验证域名解析 + 端到端测试
  01:00  迁移完成，保留 Render 24-48h 备用
D+2:  确认无问题后关闭 Render 服务和数据库
```

---

## 签署流程深入分析（后续优化方向）

迁移到同区域后，以下问题不再紧急（延迟从 100ms 降到 1ms 后影响可忽略），但记录供后续参考：

### 签署全流程 DB 操作链

| 阶段 | 文件 | DB 往返 | @100ms | @1ms |
|------|------|---------|--------|------|
| 加载签署页 | `get-envelope-for-recipient-signing.ts` | 3-4 | 400ms | 4ms |
| 签署单字段 | `sign-field-with-token.ts` | 7 | 700ms | 7ms |
| 完成签署 | `complete-document-with-token.ts` | 10-16 | 1.6s | 16ms |
| **合计** | — | **20-27** | **2.7s** | **27ms** |

### 主要浪费点

1. **Envelope 被查询 3-4 次**: 各阶段重复加载
2. **`signature.findFirst` 重复查询**: envelope include 已含 signature
3. **3 个独立事务**: 可合并减少连接开销
4. **全部顺序执行**: 无并行查询

### 相关文件的其他问题

- **`set-document-recipients.ts`**: 有部分跳过优化（lines 164-169 跳过已交互的不可修改 recipients），但"可修改但未变更"的 recipients 仍被多余 upsert。与 001 的 set-fields 问题类似但不完全相同。
- **`update-envelope-fields.ts`**: 同样的 Promise.all upsert 模式

# Documenso 本地开发环境部署计划

## 背景

目标：在 macOS 上搭建 Documenso 本地开发环境（源码运行，支持热更新）。
当前状态：已安装 Docker Desktop；Node.js 22+ 尚未安装；PDF 签名功能需要工作。

---

## 前置检查

在开始前，确认 Docker Desktop 正在运行，且所需端口未被占用：

```bash
# 确认 Docker 正在运行
docker info > /dev/null 2>&1 && echo "Docker OK" || echo "请先启动 Docker Desktop"

# 检查关键端口是否被占用（无输出表示端口空闲）
lsof -i :3000 -i :54320 -i :9000 -i :9001 -i :9002 -i :2500 -i :1100
```

若有端口被占用，需先停止占用该端口的进程，再继续后续步骤。

---

## 阶段一：安装 Node.js 22

项目要求 Node.js ≥ 22.0.0、npm ≥ 10.7.0。

```bash
# 推荐方式：用 nvm 安装，便于版本切换
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

# 重启终端后，安装并激活 Node 22
nvm install 22
nvm use 22

# 验证版本
node --version   # 应输出 v22.x.x
npm --version    # 应输出 10.x.x
```

---

## 阶段二：配置环境变量

```bash
cd /Volumes/M4_external/Aline/Documenso
cp .env.example .env
```

`.env.example` 中已预设了大部分变量的默认值，**对于本地开发，直接 `cp` 后不做任何修改即可启动**。

> **注意**：`.env.example` 中的加密密钥 `CAFEBABE` 和 `DEADBEEF` 虽未达到注释中建议的 32 字符长度，但**当前代码中并无运行时校验**，本地开发完全可以正常使用。出于安全最佳实践，建议在正式部署时替换为更长的随机密钥：

```bash
# 生成 32 字符以上的随机密钥（推荐）
openssl rand -hex 32   # 用于 NEXTAUTH_SECRET
openssl rand -hex 32   # 用于 NEXT_PRIVATE_ENCRYPTION_KEY
openssl rand -hex 32   # 用于 NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY
```

在 `.env` 中替换对应值即可。

其余变量（数据库 URL、SMTP、MinIO）使用 `.env.example` 的默认值即可，与 Docker 配置完全匹配。

> **存储说明**：`.env.example` 默认 `NEXT_PUBLIC_UPLOAD_TRANSPORT="database"`（文件存储在数据库中）。MinIO 服务虽会启动，但仅在将此值改为 `"s3"` 后才会被使用。本地开发使用 `database` 即可。

---

## 阶段三：PDF 签名证书（无需配置）

开发模式下，代码会**自动加载**内置示例证书 `apps/remix/example/cert.p12`（空密码），**无需设置任何环境变量**。

相关代码逻辑（`packages/signing/transports/local.ts`）：
1. 优先读取 `NEXT_PRIVATE_SIGNING_LOCAL_FILE_CONTENTS`（Base64）
2. 其次读取 `NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH`（文件路径）
3. **开发模式兜底**：自动使用 `./example/cert.p12`（相对于 Remix 应用工作目录）

因此，本地开发**直接跳过此步即可**，签名功能开箱即用。

> 如需替换为自定义证书（生产环境或特殊需求），参见文末附录。

---

## 阶段四：一键启动（推荐）

```bash
npm run d
```

> 首次运行约需 5-10 分钟（安装依赖、生成 Prisma Client、执行数据库迁移、编译翻译等）。

此命令依次执行：
1. `npm ci` — 安装所有依赖
2. `docker compose -f docker/development/compose.yml up -d` — 启动 PostgreSQL、Inbucket、MinIO
3. `npm run prisma:migrate-dev` — 创建数据库表结构
4. `npm run prisma:seed` — 插入初始数据
5. `npm run translate:compile` — 编译 Lingui 翻译文件
6. `npm run dev` — 启动开发服务器

> **若失败**，可分步骤调试（见阶段四备选方案）。

### 阶段四备选：分步执行

```bash
# 步骤 1：安装依赖
npm ci

# 步骤 2：启动 Docker 服务
npm run dx:up

# 步骤 3：执行数据库迁移（若报数据库连接错误，PostgreSQL 可能尚未就绪，等待 10-15 秒后重试）
npm run prisma:migrate-dev

# 步骤 4：插入种子数据
npm run prisma:seed

# 步骤 5：编译翻译
npm run translate:compile

# 步骤 6：启动开发服务器
npm run dev
```

---

## 阶段五：验证部署

启动成功后，验证以下端点：

| 服务 | 地址 | 预期 |
|------|------|------|
| 应用主页 | http://localhost:3000 | 显示登录页面 |
| 健康检查 | http://localhost:3000/api/health | 返回包含 `status`、`timestamp`、`checks` 的 JSON |
| 邮件收件箱 | http://localhost:9000 | Inbucket Web UI |
| MinIO 控制台 | http://localhost:9001 | MinIO 管理界面（用户名 `documenso`，密码 `password`） |

> **种子数据账号**：数据库初始化后会自动创建两个账号：`example@documenso.com`（普通用户）和 `admin@documenso.com`（管理员），密码均为 `password`。也可通过 `/signup` 注册新账号。

**功能验证**：
1. 访问 http://localhost:3000/signup 注册账号
2. 查看 http://localhost:9000 确认注册邮件到达
3. 上传一份 PDF，拖入签名字段，完成签名 → 验证 PDF 签名功能

---

## 常用维护命令

```bash
# 停止 Docker 服务
npm run dx:down

# 重新启动 Docker 服务
npm run dx:up

# 打开数据库 GUI
npm run prisma:studio

# 重置数据库（⚠️ 会清空所有数据）
npm run prisma:migrate-reset

# 完全重置项目（清理 node_modules + 重新安装 + 重新生成 Prisma Client）
npm run reset:hard
```

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `.env` | 环境变量配置 |
| `docker/development/compose.yml` | 开发环境 Docker 配置 |
| `apps/remix/example/cert.p12` | 内置示例签名证书 |
| `packages/prisma/schema.prisma` | 数据库 Schema |
| `packages/trpc/server/routers/` | 所有 API 路由 |
| `apps/remix/app/` | 前端路由和页面 |

---

## 附录：自行生成自签名证书

如需替换内置证书，可用以下命令生成：

```bash
# 在项目根目录执行
mkdir -p certs

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/private.key \
  -out certs/certificate.crt \
  -subj '/C=US/ST=State/L=City/O=Documenso/CN=localhost'

openssl pkcs12 -export \
  -out certs/cert.p12 \
  -inkey certs/private.key \
  -in certs/certificate.crt \
  -passout pass:localpassword
```

在 `.env` 中设置：
```
NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH=../../certs/cert.p12
NEXT_PRIVATE_SIGNING_PASSPHRASE=localpassword
```

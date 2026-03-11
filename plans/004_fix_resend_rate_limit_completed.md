# 004 — 修复 Resend 邮件发送 429 速率限制问题

## 问题描述

生产环境（DigitalOcean）使用 Resend 作为邮件服务时，当文档有多个收件人，邮件并行发送（`Promise.all`），超过 Resend 的 **2 请求/秒** 限制，导致部分收件人收不到邮件。

**错误日志：**
```
[429]: rate_limit_exceeded Too many requests. You can only make 2 requests per second.
```

**错误来源：** `@documenso/nodemailer-resend/dist/main.js:54`

**注意：** 本地开发环境使用 Inbucket（localhost SMTP），不经过 Resend，因此本地无法复现此问题。只能在云端验证修复效果。

## 根因分析

7 个文件使用 `Promise.all`（或 `Promise.allSettled`）并行发送邮件给多个收件人：

| # | 文件 | 行号 | 场景 |
|---|------|------|------|
| 1 | `packages/lib/server-only/document/send-completed-email.ts` | L184 | 文档签署完成，发邮件给所有收件人 |
| 2 | `packages/lib/server-only/document/resend-document.ts` | L120 | 手动重发邮件给多个收件人 |
| 3 | `packages/lib/jobs/definitions/emails/send-document-cancelled-emails.handler.ts` | L86 | 文档取消（job），通知所有收件人 |
| 4 | `packages/lib/server-only/document/delete-document.ts` | L211 | 删除文档，发取消邮件给所有收件人 |
| 5 | `packages/lib/server-only/admin/admin-super-delete-document.ts` | L78 | 管理员删除文档，发取消邮件 |
| 6 | `packages/lib/server-only/recipient/set-document-recipients.ts` | L298 | 移除收件人，发通知邮件 |
| 7 | `packages/lib/server-only/organisation/create-organisation-member-invites.ts` | L143 | 组织邀请，发邀请邮件（`Promise.allSettled`） |

**不受影响的文件：**
- `send-signing-email.handler.ts` — 每个收件人是独立的 background job，天然串行
- `send-recipient-signed-email.handler.ts` — 每次只发一封
- `send-rejection-emails.handler.ts` — 每次只发两封（收件人+owner），一般不会触发限制

当收件人 ≥3 时，并行请求必然超过 2 req/s 限制。

## 修复方案

### 核心思路

1. 在 `packages/email/mailer.ts` 中新增 `sendMailWithRetry` 和 `rateLimitDelay` 工具函数
2. 将所有 7 个文件的 `Promise.all` + `mailer.sendMail` 改为 `for...of` 串行 + `sendMailWithRetry`
3. 每封邮件之间调用 `rateLimitDelay()`（600ms 延迟，Resend 限制 2 req/s = 500ms，留 100ms buffer）

### 步骤 1：修改 `packages/email/mailer.ts`

**添加 import（文件顶部）：**
```typescript
import type { SendMailOptions } from 'nodemailer';
```

**在文件末尾 `export const mailer = getTransport();` 之后添加：**

```typescript
const RATE_LIMIT_DELAY_MS = 600;
const MAX_RETRIES = 3;
const RETRY_BASE_DELAY_MS = 1000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Send an email with retry logic for rate limit (429) errors.
 * Retries with exponential backoff: 1s, 2s, 4s.
 *
 * Note: 429 detection is based on Resend transport error format ("[429]: rate_limit_exceeded").
 * For non-Resend transports (SMTP, MailChannels), this function behaves like a normal sendMail
 * since those transports do not produce errors matching this pattern.
 */
export const sendMailWithRetry = async (options: SendMailOptions) => {
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    try {
      return await mailer.sendMail(options);
    } catch (error) {
      const isRateLimit =
        error instanceof Error &&
        (error.message.startsWith('[429]') || error.message.includes('rate_limit_exceeded'));

      if (isRateLimit && attempt < MAX_RETRIES) {
        const delay = RETRY_BASE_DELAY_MS * Math.pow(2, attempt);
        console.warn(
          `[email] Rate limited, retrying in ${delay}ms (attempt ${attempt + 1}/${MAX_RETRIES})`,
        );
        await sleep(delay);
        continue;
      }

      throw error;
    }
  }

  throw new Error('Unreachable');
};

/**
 * Delay to be used between sequential email sends to respect rate limits.
 */
export const rateLimitDelay = () => sleep(RATE_LIMIT_DELAY_MS);
```

### 步骤 2：修改 `send-completed-email.ts`

**导入变更：**
```diff
-import { mailer } from '@documenso/email/mailer';
+import { mailer, sendMailWithRetry, rateLimitDelay } from '@documenso/email/mailer';
```

> 注：`mailer` 仍需保留，因为其他单封邮件位置可能引用。实际上 owner 邮件也改用 `sendMailWithRetry`。

**L143 — Owner 邮件发送：**
```diff
-    await mailer.sendMail({
+    await sendMailWithRetry({
```

**L176-250 — 收件人邮件（`Promise.all` 改为 `for...of`）：**

注意：owner 邮件发送受 `isOwnerDocumentCompletedEmailEnabled` 条件控制，可能未发送。因此不用无条件延迟，而是用 `hasSentEmail` 标志统一管理。在 owner 邮件的 `if` 块外声明，owner 邮件发送成功后设为 `true`。

在 owner 邮件 `if` 块的 audit log 之后添加：
```typescript
    hasSentEmail = true;
```

替换整个 `await Promise.all(recipientsToNotify.map(...))` 块为（注意 `hasSentEmail` 已在 owner `if` 块外声明）：

```typescript
// hasSentEmail 已在 owner 邮件 if 块之前声明
// let hasSentEmail = false;

for (const recipient of recipientsToNotify) {
  if (hasSentEmail) {
    await rateLimitDelay();
  }

  const customEmailTemplate = {
    'signer.name': recipient.name,
    'signer.email': recipient.email,
    'document.name': envelope.title,
  };

  const downloadLink = `${NEXT_PUBLIC_WEBAPP_URL()}/sign/${recipient.token}/complete`;

  const template = createElement(DocumentCompletedEmailTemplate, {
    documentName: envelope.title,
    assetBaseUrl,
    downloadLink: recipient.email === owner.email ? documentOwnerDownloadLink : downloadLink,
    customBody:
      isDirectTemplate && envelope.documentMeta?.message
        ? renderCustomEmailTemplate(envelope.documentMeta.message, customEmailTemplate)
        : undefined,
  });

  const [html, text] = await Promise.all([
    renderEmailWithI18N(template, { lang: emailLanguage, branding }),
    renderEmailWithI18N(template, {
      lang: emailLanguage,
      branding,
      plainText: true,
    }),
  ]);

  const i18n = await getI18nInstance(emailLanguage);

  await sendMailWithRetry({
    to: [
      {
        name: recipient.name,
        address: recipient.email,
      },
    ],
    from: senderEmail,
    replyTo: replyToEmail,
    subject:
      isDirectTemplate && envelope.documentMeta?.subject
        ? renderCustomEmailTemplate(envelope.documentMeta.subject, customEmailTemplate)
        : i18n._(msg`Signing Complete!`),
    html,
    text,
    attachments: completedDocumentEmailAttachments,
  });

  await prisma.documentAuditLog.create({
    data: createDocumentAuditLogData({
      type: DOCUMENT_AUDIT_LOG_TYPE.EMAIL_SENT,
      envelopeId: envelope.id,
      user: null,
      requestMetadata,
      data: {
        emailType: 'DOCUMENT_COMPLETED',
        recipientEmail: recipient.email,
        recipientName: recipient.name,
        recipientId: recipient.id,
        recipientRole: recipient.role,
        isResending: false,
      },
    }),
  });

  hasSentEmail = true;
}
```

### 步骤 3：修改 `resend-document.ts`

**导入变更：**
```diff
-import { mailer } from '@documenso/email/mailer';
+import { sendMailWithRetry, rateLimitDelay } from '@documenso/email/mailer';
```

**L120-233 — 并行改串行 + 拆分 transaction：**

原代码在 `Promise.all` 内部每个收件人有一个 `prisma.$transaction` 包裹 `mailer.sendMail` + `documentAuditLog.create`。问题是网络 I/O（邮件发送 + 可能的重试）在 transaction 内部会长时间持有数据库连接。

改为：先发邮件，成功后再写 audit log（无需 transaction，因为两个操作独立且邮件发送幂等）。

```typescript
let hasSentEmail = false;

for (const recipient of recipientsToRemind) {
  if (recipient.role === RecipientRole.CC || !isRecipientEmailValidForSending(recipient)) {
    continue;
  }

  if (hasSentEmail) {
    await rateLimitDelay();
  }

  const i18n = await getI18nInstance(emailLanguage);
  const recipientEmailType = RECIPIENT_ROLE_TO_EMAIL_TYPE[recipient.role];
  const { email, name } = recipient;
  const selfSigner = email === user.email;

  const recipientActionVerb = i18n
    ._(RECIPIENT_ROLES_DESCRIPTION[recipient.role].actionVerb)
    .toLowerCase();

  let emailMessage = envelope.documentMeta.message || '';
  let emailSubject = i18n._(msg`Reminder: Please ${recipientActionVerb} this document`);

  if (selfSigner) {
    emailMessage = i18n._(
      msg`You have initiated the document ${`"${envelope.title}"`} that requires you to ${recipientActionVerb} it.`,
    );
    emailSubject = i18n._(msg`Reminder: Please ${recipientActionVerb} your document`);
  }

  if (organisationType === OrganisationType.ORGANISATION) {
    emailSubject = i18n._(
      msg`Reminder: ${envelope.team.name} invited you to ${recipientActionVerb} a document`,
    );
    emailMessage =
      envelope.documentMeta.message ||
      i18n._(
        msg`${user.name || user.email} on behalf of "${envelope.team.name}" has invited you to ${recipientActionVerb} the document "${envelope.title}".`,
      );
  }

  const customEmailTemplate = {
    'signer.name': name,
    'signer.email': email,
    'document.name': envelope.title,
  };

  const assetBaseUrl = NEXT_PUBLIC_WEBAPP_URL() || 'http://localhost:3000';
  const signDocumentLink = `${NEXT_PUBLIC_WEBAPP_URL()}/sign/${recipient.token}`;

  const template = createElement(DocumentInviteEmailTemplate, {
    documentName: envelope.title,
    inviterName: user.name || undefined,
    inviterEmail:
      organisationType === OrganisationType.ORGANISATION
        ? envelope.team?.teamEmail?.email || user.email
        : user.email,
    assetBaseUrl,
    signDocumentLink,
    customBody: renderCustomEmailTemplate(emailMessage, customEmailTemplate),
    role: recipient.role,
    selfSigner,
    organisationType,
    teamName: envelope.team?.name,
  });

  const [html, text] = await Promise.all([
    renderEmailWithI18N(template, { lang: emailLanguage, branding }),
    renderEmailWithI18N(template, { lang: emailLanguage, branding, plainText: true }),
  ]);

  await sendMailWithRetry({
    to: { address: email, name },
    from: senderEmail,
    replyTo: replyToEmail,
    subject: envelope.documentMeta.subject
      ? renderCustomEmailTemplate(
          i18n._(msg`Reminder: ${envelope.documentMeta.subject}`),
          customEmailTemplate,
        )
      : emailSubject,
    html,
    text,
  });

  await prisma.documentAuditLog.create({
    data: createDocumentAuditLogData({
      type: DOCUMENT_AUDIT_LOG_TYPE.EMAIL_SENT,
      envelopeId: envelope.id,
      metadata: requestMetadata,
      data: {
        emailType: recipientEmailType,
        recipientEmail: recipient.email,
        recipientName: recipient.name,
        recipientRole: recipient.role,
        recipientId: recipient.id,
        isResending: true,
      },
    }),
  });

  hasSentEmail = true;
}
```

### 步骤 4：修改 `send-document-cancelled-emails.handler.ts`

**导入变更：**
```diff
-import { mailer } from '@documenso/email/mailer';
+import { sendMailWithRetry, rateLimitDelay } from '@documenso/email/mailer';
```

**L86-117 — `Promise.all` 改为 `for...of`：**

```typescript
await io.runTask('send-cancellation-emails', async () => {
  let hasSentEmail = false;

  for (const recipient of recipientsToNotify) {
    if (hasSentEmail) {
      await rateLimitDelay();
    }

    const template = createElement(DocumentCancelTemplate, {
      documentName: envelope.title,
      inviterName: documentOwner.name || undefined,
      inviterEmail: documentOwner.email,
      assetBaseUrl: NEXT_PUBLIC_WEBAPP_URL(),
      cancellationReason: cancellationReason || 'The document has been cancelled.',
    });

    const [html, text] = await Promise.all([
      renderEmailWithI18N(template, { lang: emailLanguage, branding }),
      renderEmailWithI18N(template, { lang: emailLanguage, branding, plainText: true }),
    ]);

    await sendMailWithRetry({
      to: { name: recipient.name, address: recipient.email },
      from: senderEmail,
      replyTo: replyToEmail,
      subject: i18n._(msg`Document "${envelope.title}" Cancelled`),
      html,
      text,
    });

    hasSentEmail = true;
  }
});
```

### 步骤 5：修改 `delete-document.ts`

**导入变更：**
```diff
-import { mailer } from '@documenso/email/mailer';
+import { sendMailWithRetry, rateLimitDelay } from '@documenso/email/mailer';
```

**L211-249 — `Promise.all` 改为 `for...of`：**

```typescript
const i18n = await getI18nInstance(emailLanguage);
let hasSentEmail = false;

for (const recipient of envelope.recipients) {
  if (recipient.sendStatus !== SendStatus.SENT || !isRecipientEmailValidForSending(recipient)) {
    continue;
  }

  if (hasSentEmail) {
    await rateLimitDelay();
  }

  const assetBaseUrl = NEXT_PUBLIC_WEBAPP_URL() || 'http://localhost:3000';

  const template = createElement(DocumentCancelTemplate, {
    documentName: envelope.title,
    inviterName: user.name || undefined,
    inviterEmail: user.email,
    assetBaseUrl,
  });

  const [html, text] = await Promise.all([
    renderEmailWithI18N(template, { lang: emailLanguage, branding }),
    renderEmailWithI18N(template, {
      lang: emailLanguage,
      branding,
      plainText: true,
    }),
  ]);

  await sendMailWithRetry({
    to: {
      address: recipient.email,
      name: recipient.name,
    },
    from: senderEmail,
    replyTo: replyToEmail,
    subject: i18n._(msg`Document Cancelled`),
    html,
    text,
  });

  hasSentEmail = true;
}
```

### 步骤 6：修改 `admin-super-delete-document.ts`

**导入变更：**
```diff
-import { mailer } from '@documenso/email/mailer';
+import { sendMailWithRetry, rateLimitDelay } from '@documenso/email/mailer';
```

**L78-117 — `Promise.all` 改为 `for...of`：**

```typescript
const lang = envelope.documentMeta?.language ?? settings.documentLanguage;
const i18n = await getI18nInstance(lang);
let hasSentEmail = false;

for (const recipient of recipientsToNotify) {
  if (recipient.sendStatus !== SendStatus.SENT) {
    continue;
  }

  if (hasSentEmail) {
    await rateLimitDelay();
  }

  const assetBaseUrl = NEXT_PUBLIC_WEBAPP_URL() || 'http://localhost:3000';
  const template = createElement(DocumentCancelTemplate, {
    documentName: envelope.title,
    inviterName: user.name || undefined,
    inviterEmail: user.email,
    assetBaseUrl,
  });

  const [html, text] = await Promise.all([
    renderEmailWithI18N(template, { lang, branding }),
    renderEmailWithI18N(template, {
      lang,
      branding,
      plainText: true,
    }),
  ]);

  await sendMailWithRetry({
    to: {
      address: recipient.email,
      name: recipient.name,
    },
    from: senderEmail,
    replyTo: replyToEmail,
    subject: i18n._(msg`Document Cancelled`),
    html,
    text,
  });

  hasSentEmail = true;
}
```

### 步骤 7：修改 `set-document-recipients.ts`

**导入变更：**
```diff
-import { mailer } from '@documenso/email/mailer';
+import { sendMailWithRetry, rateLimitDelay } from '@documenso/email/mailer';
```

**L298-336 — `Promise.all` 改为 `for...of`：**

```typescript
let hasSentEmail = false;

for (const recipient of removedRecipients) {
  if (
    recipient.sendStatus !== SendStatus.SENT ||
    recipient.role === RecipientRole.CC ||
    !isRecipientRemovedEmailEnabled ||
    !isRecipientEmailValidForSending(recipient)
  ) {
    continue;
  }

  if (hasSentEmail) {
    await rateLimitDelay();
  }

  const assetBaseUrl = NEXT_PUBLIC_WEBAPP_URL() || 'http://localhost:3000';

  const template = createElement(RecipientRemovedFromDocumentTemplate, {
    documentName: envelope.title,
    inviterName: user.name || undefined,
    assetBaseUrl,
  });

  const [html, text] = await Promise.all([
    renderEmailWithI18N(template, { lang: emailLanguage, branding }),
    renderEmailWithI18N(template, { lang: emailLanguage, branding, plainText: true }),
  ]);

  const i18n = await getI18nInstance(emailLanguage);

  await sendMailWithRetry({
    to: {
      address: recipient.email,
      name: recipient.name,
    },
    from: senderEmail,
    replyTo: replyToEmail,
    subject: i18n._(msg`You have been removed from a document`),
    html,
    text,
  });

  hasSentEmail = true;
}
```

### 步骤 8：修改 `create-organisation-member-invites.ts`

原代码使用 `Promise.allSettled` 收集失败结果，需要保留失败收集逻辑。

同时需要修改 `sendOrganisationMemberInviteEmail` 函数（同文件 L214），将其中的 `mailer.sendMail` 改为 `sendMailWithRetry`：

**导入变更：**
```diff
-import { mailer } from '@documenso/email/mailer';
+import { sendMailWithRetry, rateLimitDelay } from '@documenso/email/mailer';
```

**`sendOrganisationMemberInviteEmail` 函数内部（L214）：**
```diff
-  await mailer.sendMail({
+  await sendMailWithRetry({
```

**L143-165 — `Promise.allSettled` 改为串行：**

```typescript
const sendEmailErrors: Array<{ email: string; error: unknown }> = [];
let hasSentEmail = false;

for (const { email, token } of organisationMemberInvites) {
  if (hasSentEmail) {
    await rateLimitDelay();
  }

  try {
    await sendOrganisationMemberInviteEmail({
      email,
      token,
      organisation,
      senderName: userName,
    });
  } catch (error) {
    sendEmailErrors.push({ email, error });
  }

  hasSentEmail = true;
}

if (sendEmailErrors.length > 0) {
  console.error(JSON.stringify(sendEmailErrors));

  throw new AppError('EmailDeliveryFailed', {
    message: 'Failed to send invite emails to one or more users.',
    userMessage: `Failed to send invites to ${sendEmailErrors.length}/${organisationMemberInvites.length} users.`,
  });
}
```

## 影响范围

- **性能影响：** 每多一个收件人增加 ~600ms 延迟。10 个收件人约增加 6 秒。可接受，因为这些操作要么是后台 job，要么是用户触发的批量操作。
- **无 breaking changes：** `mailer` 对象仍然导出，其他使用 `mailer.sendMail` 的单封邮件发送代码无需修改（如 `send-signing-email.handler.ts`）。
- **重试安全：** 邮件发送是幂等的（重复发送最多导致用户收到两封，不会造成数据问题）。`sendMailWithRetry` 对永久性错误（如无效邮箱）也会重试 3 次才抛出，这增加了少量延迟但不影响最终行为。
- **`resend-document.ts` 的 transaction 拆除：** 原来的 `$transaction` 包裹邮件发送是不合理的设计（网络 I/O 不应在 DB transaction 内）。拆开后行为更安全 — 即使 audit log 写入失败，邮件已发出；即使邮件发送失败，不会有孤立的 audit log。
- **`delete-document.ts` 行为变化：** 改为串行后，如果中间某封邮件发送失败（重试耗尽后），后续收件人的邮件不会发送（原来 `Promise.all` 也是如此 — 一个失败全部 reject）。实际上串行模式更好：失败前的收件人已成功收到邮件，而不是全部失败。
- **非 Resend transport：** `rateLimitDelay()` 在 SMTP/MailChannels transport 下也会执行，每个收件人多 600ms。对开发环境无害（Inbucket 不会有大量收件人场景）。`sendMailWithRetry` 的 429 检测只匹配 Resend 的错误格式，对其他 transport 等同于普通 `sendMail`。

## 已知限制

- **跨函数并发：** 本方案只在单个函数内串行化邮件发送。如果两个操作（如同时删除两个文档）并发执行，各自的邮件流仍可能共同超过 2 req/s。`sendMailWithRetry` 的重试机制可以兜底，但无法完全杜绝偶发 429。完整解决需要全局限流队列，但对当前使用规模来说过度工程。

## 回滚方案

如果部署后出现问题，可以快速回滚：
- `git revert` 该次提交即可恢复 `Promise.all` 并行发送
- 回滚后 429 问题会重新出现，但不会比修复前更差

## 验证方式

1. 部署后，创建一个有 3+ 收件人的文档并完成签署
2. 检查所有收件人是否都收到完成邮件
3. 检查 runtime log 确认无 429 错误
4. 检查 Resend dashboard 确认所有邮件状态为 delivered
5. 测试重发功能（resend）对多个收件人
6. 测试删除文档时的取消邮件发送

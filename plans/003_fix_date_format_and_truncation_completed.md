# 003 Fix Date Field Format and Truncation

## Problem

Signing page date field shows "2026-03-" truncated in a tiny box. Two issues:
1. Date format still uses old `yyyy-MM-dd hh:mm a` (19 chars) despite changing the TypeScript constant
2. Field box too small to display the full date text

## Root Cause Analysis

Changing `DEFAULT_DOCUMENT_DATE_FORMAT` in `packages/lib/constants/date-formats.ts` is **insufficient** because the format is stored at multiple layers in the database:

### Data Flow (why the constant is ignored)
```
OrganisationGlobalSettings.documentDateFormat (DB: 'yyyy-MM-dd hh:mm a')
  ↓ merged via extractDerivedTeamSettings()
TeamGlobalSettings.documentDateFormat (DB: null = inherit from org)
  ↓ passed to extractDerivedDocumentMeta()
DocumentMeta.dateFormat (DB: 'yyyy-MM-dd hh:mm a')
  ↓ used at signing time
sign-field-with-token.ts:201 → DateTime.now().toFormat(documentMeta.dateFormat)
  ↓ also used at display time
convertToLocalSystemFormat(customText, dateFormat) → DateTime.fromFormat(customText, dateFormat)
```

The TypeScript constant `DEFAULT_DOCUMENT_DATE_FORMAT` is only used as a **fallback when DB value is null**, but Prisma `@default` ensures most records get the old format at creation time.

### Hardcoded Locations (3 places)
| Location | File | Line |
|----------|------|------|
| DocumentMeta.dateFormat | `packages/prisma/schema.prisma` | 509 |
| OrganisationGlobalSettings.documentDateFormat | `packages/prisma/schema.prisma` | 822 |
| TypeScript constant (already changed) | `packages/lib/constants/date-formats.ts` | 5 |

## Fix Plan

### Step 1: Update Prisma Schema Defaults
**File:** `packages/prisma/schema.prisma`
- Line 509: Change `@default("yyyy-MM-dd hh:mm a")` to `@default("dd-MM-yyyy")`
- Line 822: Change `@default("yyyy-MM-dd hh:mm a")` to `@default("dd-MM-yyyy")`

### Step 2: Create Database Migration
Run `npm run prisma:migrate-dev` to generate migration, then add data migration SQL:

```sql
-- Update organisation settings (affects all new documents going forward)
UPDATE "OrganisationGlobalSettings"
SET "documentDateFormat" = 'dd-MM-yyyy'
WHERE "documentDateFormat" = 'yyyy-MM-dd hh:mm a';

-- Update team settings that explicitly use the old format
UPDATE "TeamGlobalSettings"
SET "documentDateFormat" = 'dd-MM-yyyy'
WHERE "documentDateFormat" = 'yyyy-MM-dd hh:mm a';

-- IMPORTANT: DocumentMeta records are intentionally NOT updated.
-- Each DocumentMeta.dateFormat is used BOTH at sign-time (to format the date)
-- AND at display-time (to PARSE the already-stored customText back).
-- convertToLocalSystemFormat() calls DateTime.fromFormat(customText, dateFormat).
-- If we change dateFormat on a document with already-signed date fields,
-- the parse will fail and show "Invalid date".
-- New documents will inherit 'dd-MM-yyyy' from updated org/team settings.
```

After schema changes, run:
```bash
npm run prisma:generate    # Regenerate Prisma client
npm run prisma:migrate-dev # Create and apply migration
```

### Step 3: Update Webhook Sample Data
Update hardcoded old format strings for consistency:
- `packages/lib/server-only/webhooks/trigger/generate-sample-data.ts:419` — change to `dd-MM-yyyy`
- `packages/lib/types/webhook-payload.ts:151` — change to `dd-MM-yyyy`
- `apps/documentation/pages/developers/webhooks.mdx:575` — change sample JSON to `dd-MM-yyyy`

### Step 4: No Additional UI/Logic Changes Needed
Previous commit (a58ee815) already handled:
- `date-formats.ts` — DEFAULT constant changed to `dd-MM-yyyy`
- `document-signing-date-field.tsx:154` — `whitespace-nowrap` -> `whitespace-pre-wrap` (text wrapping fix)
- `stepper-component.spec.ts` — E2E test updated

## Safety Analysis

- **OrganisationGlobalSettings / TeamGlobalSettings**: These are "template" settings that feed into new documents. Changing them only affects documents created after the migration. Safe.
- **Prisma @default**: Only affects newly created database rows. Safe.
- **Existing DocumentMeta records**: Left unchanged intentionally. Documents retain whatever format was active when they were created. Already-signed date fields continue to display correctly because `convertToLocalSystemFormat()` parses `customText` with the matching original format.
- **New documents**: Will inherit `dd-MM-yyyy` from updated org/team settings via `extractDerivedDocumentMeta()`. The shorter format (10 chars vs 19 chars) fits much better in field boxes.

## Verification
1. After migration: `SELECT "documentDateFormat" FROM "OrganisationGlobalSettings";` → should show `dd-MM-yyyy`
2. Create a **new** document with a date field, send for signing
3. Date field should show format like "05-03-2026" (10 chars, fits in field box)
4. Check an existing PENDING document with signed date fields — should still display dates correctly (no "Invalid date")

## Key Files Reference
- `packages/prisma/schema.prisma:509,822` — Prisma defaults
- `packages/lib/constants/date-formats.ts:5` — TypeScript constant
- `packages/lib/constants/date-formats.ts:157-176` — `convertToLocalSystemFormat()` (parses customText using dateFormat)
- `packages/lib/utils/document.ts:46` — Format derivation logic
- `packages/lib/utils/teams.ts:218-237` — Team settings merge
- `packages/lib/utils/organisations.ts:119` — Org default generation
- `packages/lib/server-only/field/sign-field-with-token.ts:198-202` — Date formatting at sign time
- `apps/remix/app/components/general/document-signing/document-signing-date-field.tsx:62,154` — UI rendering & parsing

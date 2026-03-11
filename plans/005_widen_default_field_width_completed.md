# 005 — Widen Default Field Width by 50%

## Context

After deploying to the cloud, name fields (and other text fields like EMAIL) are too narrow, causing text to be truncated in the final PDF. The default width was previously increased from 90px to 126px (commit 0e3cef32) to fix date truncation, but this is still insufficient for longer names and emails.

**Goal**: Increase the default width of all field types by 50% (126px → 189px) so text content displays fully in the signed PDF.

## Change

Update `DEFAULT_WIDTH_PX` multiplier from `3.5` to `5.25` in all 4 files where it's defined:

| # | File | Line(s) |
|---|------|---------|
| 1 | `packages/ui/primitives/document-flow/add-fields.tsx` | ~63-67 |
| 2 | `packages/ui/primitives/template-flow/add-template-fields.tsx` | ~70-74 |
| 3 | `apps/remix/app/components/embed/authoring/configure-fields-view.tsx` | ~36-40 |
| 4 | `apps/remix/app/components/general/envelope-editor/envelope-editor-fields-drag-drop.tsx` | ~30-34 |

**Current:**
```ts
const DEFAULT_WIDTH_PX = MIN_WIDTH_PX * 3.5;  // 36 * 3.5 = 126px
```

**New:**
```ts
const DEFAULT_WIDTH_PX = MIN_WIDTH_PX * 5.25;  // 36 * 5.25 = 189px
```

**Note**: This only affects **newly placed** fields. Existing fields already saved in the database retain their stored dimensions.

## Verification

1. Run `npm run dev` and open the envelope editor
2. Drag a NAME, EMAIL, and DATE field onto a document page
3. Confirm the default box is visibly wider (~189px vs previous 126px)
4. Complete a signing flow with a long name (25+ chars) and email (35+ chars) — verify text is not truncated in the PDF
5. Confirm existing documents with previously placed fields are unaffected
6. Drag a field near the right edge of a page — confirm it does not overflow or cause layout issues

## Follow-up / Tech Debt

The constants `MIN_HEIGHT_PX`, `MIN_WIDTH_PX`, `DEFAULT_HEIGHT_PX`, `DEFAULT_WIDTH_PX` are duplicated identically across all 4 files. Consider extracting them into a shared constants module to eliminate lockstep updates in the future.

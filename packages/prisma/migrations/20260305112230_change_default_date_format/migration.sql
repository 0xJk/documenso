-- AlterTable
ALTER TABLE "DocumentMeta" ALTER COLUMN "dateFormat" SET DEFAULT 'dd-MM-yyyy';

-- AlterTable
ALTER TABLE "OrganisationGlobalSettings" ALTER COLUMN "documentDateFormat" SET DEFAULT 'dd-MM-yyyy';

-- Data Migration: Update organisation settings (affects all new documents going forward)
UPDATE "OrganisationGlobalSettings"
SET "documentDateFormat" = 'dd-MM-yyyy'
WHERE "documentDateFormat" = 'yyyy-MM-dd hh:mm a';

-- Data Migration: Update team settings that explicitly use the old format
UPDATE "TeamGlobalSettings"
SET "documentDateFormat" = 'dd-MM-yyyy'
WHERE "documentDateFormat" = 'yyyy-MM-dd hh:mm a';

-- NOTE: DocumentMeta records are intentionally NOT updated.
-- Each DocumentMeta.dateFormat is used BOTH at sign-time (to format the date)
-- AND at display-time (to PARSE the already-stored customText back).
-- Changing dateFormat on documents with already-signed date fields would break parsing.

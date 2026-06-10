-- ============================================================================
-- One-time migration: v1 (attachments_current + stale_attachments) -> v2
--
-- Prerequisite: run run_me_first.sql first so the v2 tables exist.
--
-- This script is IDEMPOTENT. It can be re-run safely as a "top-up" to pick
-- up rows the old ingest wrote between the first migration pass and the
-- deployment of the new attachments_ingest.php.
--
-- Recommended sequence:
--   1. Run run_me_first.sql            (creates v2 tables, proc, views)
--   2. Run this script                 (initial migration)
--   3. Deploy the new attachments_ingest.php
--   4. Re-run this script              (top-up for rows ingested during 2-3)
--   5. Verify counts (see bottom), then run the DROP section manually
--
-- NOTE: adjust the database name if your live DB is prefixed.
-- ============================================================================

USE `avscanner`;

-- ----------------------------------------------------------------------------
-- 1. Avatars: latest name wins, seen range spans both old tables
-- ----------------------------------------------------------------------------

INSERT INTO `avatars` (`avatar_uuid`, `avatar_name`, `first_seen_utc`, `last_seen_utc`)
SELECT
    UNHEX(REPLACE(x.`avatar_uuid`, '-', '')),
    x.`avatar_name`,
    x.`first_seen`,
    x.`last_seen`
FROM (
    SELECT
        u.`avatar_uuid`,
        u.`avatar_name`,
        MIN(u.`first_seen_utc`) OVER (PARTITION BY u.`avatar_uuid`) AS `first_seen`,
        MAX(u.`changed_utc`)    OVER (PARTITION BY u.`avatar_uuid`) AS `last_seen`,
        ROW_NUMBER() OVER (PARTITION BY u.`avatar_uuid` ORDER BY u.`changed_utc` DESC) AS rn
    FROM (
        SELECT `avatar_uuid`, `avatar_name`, `first_seen_utc`, `changed_utc` FROM `attachments_current`
        UNION ALL
        SELECT `avatar_uuid`, `avatar_name`, `first_seen_utc`, `changed_utc` FROM `stale_attachments`
    ) u
) x
WHERE x.rn = 1
ON DUPLICATE KEY UPDATE
    -- only let old data overwrite the name if it is at least as fresh
    -- (columns are table-qualified: bare names are ambiguous in INSERT..SELECT..ODKU)
    `avatar_name`    = IF(VALUES(`last_seen_utc`) >= `avatars`.`last_seen_utc`, VALUES(`avatar_name`), `avatars`.`avatar_name`),
    `first_seen_utc` = LEAST(`avatars`.`first_seen_utc`, VALUES(`first_seen_utc`)),
    `last_seen_utc`  = GREATEST(`avatars`.`last_seen_utc`, VALUES(`last_seen_utc`));

-- ----------------------------------------------------------------------------
-- 2. Avatar name history
-- ----------------------------------------------------------------------------

INSERT INTO `avatar_names` (`avatar_id`, `avatar_name`, `first_seen_utc`, `last_seen_utc`)
SELECT
    a.`avatar_id`,
    u.`avatar_name`,
    MIN(u.`first_seen_utc`),
    MAX(u.`changed_utc`)
FROM (
    SELECT `avatar_uuid`, `avatar_name`, `first_seen_utc`, `changed_utc` FROM `attachments_current`
    UNION ALL
    SELECT `avatar_uuid`, `avatar_name`, `first_seen_utc`, `changed_utc` FROM `stale_attachments`
) u
JOIN `avatars` a ON a.`avatar_uuid` = UNHEX(REPLACE(u.`avatar_uuid`, '-', ''))
GROUP BY a.`avatar_id`, u.`avatar_name`
ON DUPLICATE KEY UPDATE
    `first_seen_utc` = LEAST(`avatar_names`.`first_seen_utc`, VALUES(`first_seen_utc`)),
    `last_seen_utc`  = GREATEST(`avatar_names`.`last_seen_utc`, VALUES(`last_seen_utc`));

-- ----------------------------------------------------------------------------
-- 3. Deduplicated object definitions
-- ----------------------------------------------------------------------------

INSERT INTO `objects` (`object_name`, `object_desc`, `sig_hash`)
SELECT DISTINCT
    u.`attachment_name`,
    u.`attachment_desc`,
    UNHEX(MD5(CONCAT(u.`attachment_name`, CHAR(31), u.`attachment_desc`)))
FROM (
    SELECT `attachment_name`, `attachment_desc` FROM `attachments_current`
    UNION ALL
    SELECT `attachment_name`, `attachment_desc` FROM `stale_attachments`
) u
ON DUPLICATE KEY UPDATE `object_id` = `object_id`;

-- ----------------------------------------------------------------------------
-- 4. Sightings: collapse v1 rows (which split on attachment UUID, i.e. every
--    relog) into one row per (avatar, object, attach point)
-- ----------------------------------------------------------------------------

INSERT INTO `sightings` (`avatar_id`, `object_id`, `attach_point`, `first_seen_utc`, `last_seen_utc`)
SELECT
    a.`avatar_id`,
    o.`object_id`,
    LEAST(GREATEST(u.`attached_point`, 0), 255),
    MIN(u.`first_seen_utc`),
    MAX(u.`changed_utc`)
FROM (
    SELECT `avatar_uuid`, `attachment_name`, `attachment_desc`, `attached_point`, `first_seen_utc`, `changed_utc`
    FROM `attachments_current`
    UNION ALL
    SELECT `avatar_uuid`, `attachment_name`, `attachment_desc`, `attached_point`, `first_seen_utc`, `changed_utc`
    FROM `stale_attachments`
) u
JOIN `avatars` a ON a.`avatar_uuid` = UNHEX(REPLACE(u.`avatar_uuid`, '-', ''))
JOIN `objects` o ON o.`sig_hash`    = UNHEX(MD5(CONCAT(u.`attachment_name`, CHAR(31), u.`attachment_desc`)))
GROUP BY a.`avatar_id`, o.`object_id`, LEAST(GREATEST(u.`attached_point`, 0), 255)
ON DUPLICATE KEY UPDATE
    `first_seen_utc` = LEAST(`sightings`.`first_seen_utc`, VALUES(`first_seen_utc`)),
    `last_seen_utc`  = GREATEST(`sightings`.`last_seen_utc`, VALUES(`last_seen_utc`));

-- ----------------------------------------------------------------------------
-- Verification queries (run by hand, compare the pairs)
-- ----------------------------------------------------------------------------

-- Old distinct avatars vs new:
--   SELECT COUNT(DISTINCT avatar_uuid) FROM (
--       SELECT avatar_uuid FROM attachments_current
--       UNION ALL SELECT avatar_uuid FROM stale_attachments) u;
--   SELECT COUNT(*) FROM avatars;

-- Old distinct (avatar, name, desc, point) vs new sightings:
--   SELECT COUNT(*) FROM (
--       SELECT DISTINCT avatar_uuid, attachment_name, attachment_desc, attached_point FROM (
--           SELECT avatar_uuid, attachment_name, attachment_desc, attached_point FROM attachments_current
--           UNION ALL
--           SELECT avatar_uuid, attachment_name, attachment_desc, attached_point FROM stale_attachments) u) d;
--   SELECT COUNT(*) FROM sightings;

-- ----------------------------------------------------------------------------
-- FINAL CLEANUP: run MANUALLY only after the new ingest is deployed, the
-- top-up pass has been run, and the verification counts above match.
-- ----------------------------------------------------------------------------

-- DROP TABLE `attachments_current`;
-- DROP TABLE `stale_attachments`;

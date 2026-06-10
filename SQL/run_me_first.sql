-- ============================================================================
-- hails.AVScanner schema v2
--
-- Normalized layout:
--   avatars        one row per avatar UUID, latest name, first/last seen
--   avatar_names   every name an avatar has been seen with (history)
--   objects        deduplicated attachment definitions (name + desc)
--   sightings      one row per (avatar, object, attach point), current state
--                  AND history in one table via first_seen/last_seen ranges
--   ingest_staging raw landing zone; drained by sp_process_staging()
--
-- All UUIDs are stored as BINARY(16). Convert at the edges:
--   write: UNHEX(REPLACE(uuid_string, '-', ''))
--   read:  see uuid string expression in the views below
--
-- All timestamps are DATETIME populated with UTC_TIMESTAMP().
--
-- NOTE: database name is 'avscanner' here; the live deployment uses a
-- prefixed name. Adjust the two lines below before running if needed.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS `avscanner`;
USE `avscanner`;

-- ----------------------------------------------------------------------------
-- Core tables
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `avatars` (
  `avatar_id`      int(10) unsigned NOT NULL AUTO_INCREMENT,
  `avatar_uuid`    binary(16) NOT NULL,
  `avatar_name`    varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `first_seen_utc` datetime NOT NULL,
  `last_seen_utc`  datetime NOT NULL,
  PRIMARY KEY (`avatar_id`),
  UNIQUE KEY `uniq_avatar_uuid` (`avatar_uuid`),
  KEY `idx_avatar_name` (`avatar_name`),
  KEY `idx_last_seen` (`last_seen_utc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `avatar_names` (
  `name_id`        int(10) unsigned NOT NULL AUTO_INCREMENT,
  `avatar_id`      int(10) unsigned NOT NULL,
  `avatar_name`    varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `first_seen_utc` datetime NOT NULL,
  `last_seen_utc`  datetime NOT NULL,
  PRIMARY KEY (`name_id`),
  UNIQUE KEY `uniq_avatar_name` (`avatar_id`,`avatar_name`),
  CONSTRAINT `fk_names_avatar` FOREIGN KEY (`avatar_id`)
    REFERENCES `avatars` (`avatar_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `objects` (
  `object_id`   int(10) unsigned NOT NULL AUTO_INCREMENT,
  `object_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `object_desc` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  -- UNHEX(MD5(CONCAT(object_name, CHAR(31), object_desc)))
  `sig_hash`    binary(16) NOT NULL,
  PRIMARY KEY (`object_id`),
  UNIQUE KEY `uniq_sig_hash` (`sig_hash`),
  KEY `idx_object_name` (`object_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `sightings` (
  `sighting_id`    bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `avatar_id`      int(10) unsigned NOT NULL,
  `object_id`      int(10) unsigned NOT NULL,
  `attach_point`   tinyint(3) unsigned NOT NULL,
  `first_seen_utc` datetime NOT NULL,
  `last_seen_utc`  datetime NOT NULL,
  PRIMARY KEY (`sighting_id`),
  UNIQUE KEY `uniq_sighting` (`avatar_id`,`object_id`,`attach_point`),
  KEY `idx_object` (`object_id`),
  KEY `idx_last_seen` (`last_seen_utc`),
  CONSTRAINT `fk_sightings_avatar` FOREIGN KEY (`avatar_id`)
    REFERENCES `avatars` (`avatar_id`) ON DELETE CASCADE,
  CONSTRAINT `fk_sightings_object` FOREIGN KEY (`object_id`)
    REFERENCES `objects` (`object_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Raw landing zone. The ingest endpoint commits rows here, then calls
-- sp_process_staging() to drain them. Normally near-empty; if a call fails
-- (e.g. a deadlock between parallel nodes) the rows simply wait for the
-- next ingest call.
CREATE TABLE IF NOT EXISTS `ingest_staging` (
  `id`           bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `avatar_uuid`  binary(16) NOT NULL,
  `avatar_name`  varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `object_name`  varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `object_desc`  varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `attach_point` tinyint(3) unsigned NOT NULL,
  `received_utc` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- Ingest processor
--
-- Drains ingest_staging into the normalized tables. Set-based and idempotent:
-- concurrent calls from parallel scanner nodes may process overlapping rows,
-- which is harmless because every statement is an upsert.
-- ----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS `sp_process_staging`;

DELIMITER $$

CREATE PROCEDURE `sp_process_staging`()
BEGIN
    DECLARE batch_max BIGINT UNSIGNED;

    SELECT MAX(`id`) INTO batch_max FROM `ingest_staging`;

    IF batch_max IS NOT NULL THEN

        -- 1. Avatars: one row per UUID, newest record in the batch wins the name
        INSERT INTO `avatars` (`avatar_uuid`, `avatar_name`, `first_seen_utc`, `last_seen_utc`)
        SELECT s.`avatar_uuid`, s.`avatar_name`, UTC_TIMESTAMP(), UTC_TIMESTAMP()
        FROM `ingest_staging` s
        JOIN (
            SELECT `avatar_uuid`, MAX(`id`) AS max_id
            FROM `ingest_staging`
            WHERE `id` <= batch_max
            GROUP BY `avatar_uuid`
        ) latest ON latest.max_id = s.`id`
        ON DUPLICATE KEY UPDATE
            `avatar_name`   = VALUES(`avatar_name`),
            `last_seen_utc` = VALUES(`last_seen_utc`);

        -- 2. Name history
        INSERT INTO `avatar_names` (`avatar_id`, `avatar_name`, `first_seen_utc`, `last_seen_utc`)
        SELECT DISTINCT a.`avatar_id`, s.`avatar_name`, UTC_TIMESTAMP(), UTC_TIMESTAMP()
        FROM `ingest_staging` s
        JOIN `avatars` a ON a.`avatar_uuid` = s.`avatar_uuid`
        WHERE s.`id` <= batch_max
        ORDER BY a.`avatar_id`, s.`avatar_name`
        ON DUPLICATE KEY UPDATE
            `last_seen_utc` = VALUES(`last_seen_utc`);

        -- 3. Deduplicated object definitions
        INSERT INTO `objects` (`object_name`, `object_desc`, `sig_hash`)
        SELECT DISTINCT
            s.`object_name`,
            s.`object_desc`,
            UNHEX(MD5(CONCAT(s.`object_name`, CHAR(31), s.`object_desc`)))
        FROM `ingest_staging` s
        WHERE s.`id` <= batch_max
        ORDER BY s.`object_name`, s.`object_desc`
        ON DUPLICATE KEY UPDATE `object_id` = `object_id`;

        -- 4. Sightings: relogs and rescans just bump last_seen on the same row
        INSERT INTO `sightings` (`avatar_id`, `object_id`, `attach_point`, `first_seen_utc`, `last_seen_utc`)
        SELECT DISTINCT a.`avatar_id`, o.`object_id`, s.`attach_point`, UTC_TIMESTAMP(), UTC_TIMESTAMP()
        FROM `ingest_staging` s
        JOIN `avatars` a ON a.`avatar_uuid` = s.`avatar_uuid`
        JOIN `objects` o ON o.`sig_hash` = UNHEX(MD5(CONCAT(s.`object_name`, CHAR(31), s.`object_desc`)))
        WHERE s.`id` <= batch_max
        ORDER BY a.`avatar_id`, o.`object_id`, s.`attach_point`
        ON DUPLICATE KEY UPDATE
            `last_seen_utc` = VALUES(`last_seen_utc`);

        -- 5. Drain the processed rows
        DELETE FROM `ingest_staging` WHERE `id` <= batch_max;

    END IF;
END$$

DELIMITER ;

-- ----------------------------------------------------------------------------
-- Stats views
--
-- "Current" means: the sighting was refreshed by the avatar's most recent
-- scan. An avatar's full scan finishes well inside 10 minutes, so a sighting
-- whose last_seen lags the avatar's last_seen by more than that has been
-- removed or renamed.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW `v_current_attachments` AS
SELECT
    a.`avatar_id`,
    LOWER(CONCAT(
        SUBSTR(HEX(a.`avatar_uuid`), 1, 8), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 9, 4), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 13, 4), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 17, 4), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 21, 12)
    )) AS `avatar_uuid`,
    a.`avatar_name`,
    o.`object_name`  AS `attachment_name`,
    o.`object_desc`  AS `attachment_desc`,
    s.`attach_point`,
    s.`first_seen_utc`,
    s.`last_seen_utc`
FROM `sightings` s
JOIN `avatars` a ON a.`avatar_id` = s.`avatar_id`
JOIN `objects` o ON o.`object_id` = s.`object_id`
WHERE s.`last_seen_utc` >= a.`last_seen_utc` - INTERVAL 10 MINUTE;

CREATE OR REPLACE VIEW `v_avatar_stats` AS
SELECT
    a.`avatar_id`,
    LOWER(CONCAT(
        SUBSTR(HEX(a.`avatar_uuid`), 1, 8), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 9, 4), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 13, 4), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 17, 4), '-',
        SUBSTR(HEX(a.`avatar_uuid`), 21, 12)
    )) AS `avatar_uuid`,
    a.`avatar_name`,
    a.`first_seen_utc`,
    a.`last_seen_utc`,
    COALESCE(SUM(s.`last_seen_utc` >= a.`last_seen_utc` - INTERVAL 10 MINUTE), 0) AS `current_attachments`,
    COUNT(s.`sighting_id`) AS `items_seen_all_time`
FROM `avatars` a
LEFT JOIN `sightings` s ON s.`avatar_id` = a.`avatar_id`
GROUP BY a.`avatar_id`, a.`avatar_uuid`, a.`avatar_name`, a.`first_seen_utc`, a.`last_seen_utc`;

CREATE OR REPLACE VIEW `v_object_popularity` AS
SELECT
    o.`object_id`,
    o.`object_name`,
    o.`object_desc`,
    COUNT(DISTINCT s.`avatar_id`) AS `distinct_wearers`,
    COUNT(s.`sighting_id`)        AS `total_sightings`,
    MAX(s.`last_seen_utc`)        AS `last_seen_utc`
FROM `objects` o
LEFT JOIN `sightings` s ON s.`object_id` = o.`object_id`
GROUP BY o.`object_id`, o.`object_name`, o.`object_desc`;

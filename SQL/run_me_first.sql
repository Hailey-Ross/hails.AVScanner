CREATE DATABASE IF NOT EXISTS `avscanner`;
USE `avscanner`;

CREATE TABLE IF NOT EXISTS `attachments_current` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `avatar_uuid` char(36) COLLATE utf8mb4_unicode_ci NOT NULL,
  `avatar_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `attachment_uuid` char(36) COLLATE utf8mb4_unicode_ci NOT NULL,
  `attachment_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `attachment_desc` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `attached_point` int(11) NOT NULL DEFAULT '0',
  `data_hash` char(64) COLLATE utf8mb4_unicode_ci NOT NULL,
  `first_seen_utc` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `changed_utc` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_avatar_attachment` (`avatar_uuid`,`attachment_uuid`),
  KEY `idx_avatar_uuid` (`avatar_uuid`),
  KEY `idx_attachment_uuid` (`attachment_uuid`),
  KEY `idx_data_hash` (`data_hash`),
  KEY `idx_changed_utc` (`changed_utc`),
  KEY `idx_avatar_name` (`avatar_name`)
) ENGINE=InnoDB AUTO_INCREMENT=206 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `stale_attachments` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `current_row_id` bigint(20) unsigned NOT NULL,
  `avatar_uuid` char(36) COLLATE utf8mb4_unicode_ci NOT NULL,
  `avatar_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `attachment_uuid` char(36) COLLATE utf8mb4_unicode_ci NOT NULL,
  `attachment_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `attachment_desc` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `attached_point` int(11) NOT NULL DEFAULT '0',
  `data_hash` char(64) COLLATE utf8mb4_unicode_ci NOT NULL,
  `first_seen_utc` datetime NOT NULL,
  `changed_utc` datetime NOT NULL,
  `stale_moved_utc` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_current_row_id` (`current_row_id`),
  KEY `idx_avatar_uuid` (`avatar_uuid`),
  KEY `idx_attachment_uuid` (`attachment_uuid`),
  KEY `idx_stale_moved_utc` (`stale_moved_utc`),
  KEY `idx_changed_utc` (`changed_utc`)
) ENGINE=InnoDB AUTO_INCREMENT=91 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

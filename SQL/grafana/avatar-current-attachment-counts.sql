-- Grafana table panel: per avatar, how many items they are wearing right
-- now and when they were last seen. (Replaces the GROUP BY avatar_uuid
-- count over attachments_current.)
SELECT
    last_seen_utc       AS `Date/Time (UTC)`,
    avatar_name         AS `Avatar`,
    current_attachments AS `Attachment count`
FROM v_avatar_stats
ORDER BY `Attachment count` DESC

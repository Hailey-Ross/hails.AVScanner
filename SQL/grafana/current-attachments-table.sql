-- Grafana table panel: everything every avatar is currently wearing.
-- Avatars are blocked together, most recently active avatar first; within
-- each avatar, attachments appear in the order their entries were created
-- (received).
SELECT
    first_seen_utc  AS 'Received (UTC)',
    last_seen_utc   AS 'Last Seen (UTC)',
    avatar_name     AS 'Avatar',
    attachment_name AS 'Attachment',
    attachment_desc AS 'Description',
    attach_point    AS 'Attach Point'
FROM (
    SELECT v.*,
           MAX(last_seen_utc) OVER (PARTITION BY avatar_id) AS avatar_latest
    FROM v_current_attachments v
) t
ORDER BY avatar_latest DESC, avatar_name, first_seen_utc ASC
LIMIT 1000

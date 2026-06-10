-- Latest attachments per avatar, one row per currently worn item.
-- "Current" filtering is handled by the view (see run_me_first.sql).
SELECT
    avatar_name,
    attachment_name,
    attachment_desc,
    attach_point,
    first_seen_utc,
    last_seen_utc
FROM v_current_attachments
ORDER BY avatar_name, attach_point
LIMIT 100;

-- Other handy queries:

-- Per-avatar summary (current item count, all-time item count, seen range):
--   SELECT * FROM v_avatar_stats ORDER BY last_seen_utc DESC LIMIT 50;

-- Most popular items across all avatars:
--   SELECT * FROM v_object_popularity ORDER BY distinct_wearers DESC LIMIT 50;

-- Name history for one avatar:
--   SELECT an.* FROM avatar_names an
--   JOIN avatars a ON a.avatar_id = an.avatar_id
--   WHERE a.avatar_name = 'SomeName Resident'
--   ORDER BY an.last_seen_utc DESC;

-- Full wear history for one avatar (including items no longer worn):
--   SELECT o.object_name, o.object_desc, s.attach_point, s.first_seen_utc, s.last_seen_utc
--   FROM sightings s
--   JOIN avatars a ON a.avatar_id = s.avatar_id
--   JOIN objects o ON o.object_id = s.object_id
--   WHERE a.avatar_name = 'SomeName Resident'
--   ORDER BY s.last_seen_utc DESC;

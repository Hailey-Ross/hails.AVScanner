-- Grafana bar/table panel: per avatar, every distinct item ever seen on
-- them, including things no longer worn. (The old version of this query
-- counted raw rows per avatar_name, which inflated with every relog; v2
-- counts real distinct items.)
SELECT
    avatar_name,
    items_seen_all_time AS attachment_count
FROM v_avatar_stats
ORDER BY attachment_count DESC

-- Grafana bar/table panel: most popular items across all avatars.
-- distinct_wearers = how many different avatars have worn it, which is a
-- truer popularity measure than the old raw row count (that inflated with
-- every relog). total_sightings included for reference.
SELECT
    object_name      AS attachment_name,
    object_desc      AS description,
    distinct_wearers AS usage_count,
    total_sightings
FROM v_object_popularity
ORDER BY usage_count DESC

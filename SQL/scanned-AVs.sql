SELECT
    changed_utc,
    avatar_name,
    attachment_name,
    attachment_desc,
    attached_point
FROM (
    SELECT
        changed_utc,
        avatar_name,
        attachment_name,
        attachment_desc,
        attached_point,
        ROW_NUMBER() OVER (
            PARTITION BY avatar_name, attached_point
            ORDER BY changed_utc DESC
        ) AS rn
    FROM attachments_current
) t
WHERE rn = 1
ORDER BY avatar_name, changed_utc DESC
LIMIT 100

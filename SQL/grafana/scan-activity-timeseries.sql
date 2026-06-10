-- Grafana time series: scan activity over time (sightings refreshed per
-- timestamp). Equivalent of the old changed_utc series on
-- attachments_current.
SELECT
  last_seen_utc AS time,
  COUNT(*) AS value
FROM sightings
GROUP BY last_seen_utc
ORDER BY time ASC;

-- Variant: discovery rate instead of scan activity, i.e. how many items
-- were seen for the FIRST time at each point in time:
--   SELECT first_seen_utc AS time, COUNT(*) AS value
--   FROM sightings
--   GROUP BY first_seen_utc
--   ORDER BY time ASC;

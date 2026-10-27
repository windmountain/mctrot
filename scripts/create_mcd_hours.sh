set -euo pipefail

# Parse each McDonald's per-day hours ("HH:MM - HH:MM") into minute ranges,
# one row per location per weekday (0 = Monday ... 6 = Sunday).
#
# The API's "24 hours" label is not used: it doesn't reliably match the
# per-day hours (e.g. Macy's is labelled 24 hours but opens 08:00 - 21:00).
#
# Rules, same as the TSPTW notebooks:
#   00:00 - 00:00            open all day: 0 - 1440
#   HH:MM - 00:00            closes at midnight: close is 1440
#   close earlier than open  crosses midnight: close + 1440
#   missing or malformed     assumed open all day

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

CREATE OR REPLACE VIEW mcd_hours AS
WITH day AS (
  SELECT mcd.ogc_fid AS mcd_id, d.weekday, d.hours
  FROM mcd
  CROSS JOIN LATERAL (VALUES
    (0, mcd.restauranthoursmonday),
    (1, mcd.restauranthourstuesday),
    (2, mcd.restauranthourswednesday),
    (3, mcd.restauranthoursthursday),
    (4, mcd.restauranthoursfriday),
    (5, mcd.restauranthourssaturday),
    (6, mcd.restauranthourssunday)
  ) AS d(weekday, hours)
),
parsed AS (
  SELECT
    mcd_id,
    weekday,
    hours,
    CASE WHEN hours ~ '^\d\d:\d\d - \d\d:\d\d$'
      THEN substr(hours, 1, 2)::int * 60 + substr(hours, 4, 2)::int END AS o,
    CASE WHEN hours ~ '^\d\d:\d\d - \d\d:\d\d$'
      THEN substr(hours, 9, 2)::int * 60 + substr(hours, 12, 2)::int END AS c
  FROM day
)
SELECT
  mcd_id,
  weekday,
  hours,
  CASE
    WHEN o IS NULL OR (o = 0 AND c = 0) THEN 0
    ELSE o
  END AS open_minute,
  CASE
    WHEN o IS NULL OR (o = 0 AND c = 0) THEN 1440
    WHEN c = 0 THEN 1440
    WHEN c < o THEN c + 1440
    ELSE c
  END AS close_minute
FROM parsed;

SQL

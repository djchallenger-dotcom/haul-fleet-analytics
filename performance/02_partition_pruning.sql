/*
Performance 02: partition pruning
Scenario: total tonnes per truck for March. haul_cycle is partitioned
by month on load_start_ts, with boundaries at midnight mine-local time
(America/Phoenix). "March" can be defined by load time or dump time;
both return ~25,925 cycles, but only the partition key lets PostgreSQL
skip partitions.
Run each EXPLAIN two or three times and compare the last run.
Results and discussion: performance/tuning_notes.md
*/

-- Check: partition boundaries. Each partition should start at midnight
-- mine time (shown as 00:00:00-07 in an Arizona session, or 07:00:00+00
-- in a UTC session such as psql inside the container).
SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bounds
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'haul_cycle'::regclass
ORDER BY c.relname;

-- Version A: filter on dump_end_ts, which is not the partition key.
-- Expect a scan of all seven partitions, most returning 0 rows.
EXPLAIN (ANALYZE, BUFFERS)
SELECT truck_id, SUM(payload_tonnes) AS tonnes
FROM haul_cycle
WHERE dump_end_ts >= '2026-03-01 00:00-07'
  AND dump_end_ts <  '2026-04-01 00:00-07'
GROUP BY truck_id;

-- Version B: filter on load_start_ts, the partition key.
-- Expect a single Seq Scan on haul_cycle_2026_03 with no rows removed.
EXPLAIN (ANALYZE, BUFFERS)
SELECT truck_id, SUM(payload_tonnes) AS tonnes
FROM haul_cycle
WHERE load_start_ts >= '2026-03-01 00:00-07'
  AND load_start_ts <  '2026-04-01 00:00-07'
GROUP BY truck_id;
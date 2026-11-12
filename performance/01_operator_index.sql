/*
Performance 01: indexing a frequent filter column
Scenario: a supervisor pulls one operator's production by shift.
haul_cycle has no index on operator_id, so every lookup scans all
~150,000 rows across every monthly partition.
Run this script top to bottom. Run each EXPLAIN two or three times
and compare the last run; the first run includes warm-up time.
Results and discussion: performance/tuning_notes.md
*/

-- Reset so the "before" measurement is always taken without the index
DROP INDEX IF EXISTS haul_cycle_operator_id_idx;

-- Before: expect Seq Scan on every partition and large
-- "Rows Removed by Filter" counts
EXPLAIN (ANALYZE, BUFFERS)
SELECT shift_id, COUNT(*) AS cycles, SUM(payload_tonnes) AS tonnes
FROM haul_cycle
WHERE operator_id = 71
GROUP BY shift_id;

-- Fix: creating the index on the partitioned parent also creates one
-- on every partition. ANALYZE refreshes planner statistics.
CREATE INDEX haul_cycle_operator_id_idx ON haul_cycle (operator_id);
ANALYZE haul_cycle;

-- After: expect Bitmap Index Scan on every partition and far fewer buffers
EXPLAIN (ANALYZE, BUFFERS)
SELECT shift_id, COUNT(*) AS cycles, SUM(payload_tonnes) AS tonnes
FROM haul_cycle
WHERE operator_id = 71
GROUP BY shift_id;

-- Verify: one index on the parent plus one per partition (8 rows)
SELECT tablename, indexname
FROM pg_indexes
WHERE indexname LIKE '%operator_id%'
ORDER BY tablename;

-- Cost: total disk space used by the new indexes
SELECT pg_size_pretty(SUM(pg_relation_size(indexname::regclass)))
FROM pg_indexes
WHERE indexname LIKE 'haul_cycle%operator_id_idx';
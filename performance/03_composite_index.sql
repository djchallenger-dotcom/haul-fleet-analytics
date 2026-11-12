/*
Performance 03: composite index vs. query rewrite
Scenario: the idle-shift anti-join from queries/04_downtime_gaps.sql,
which checks every truck/shift pair for haul cycles. Its inner lookup
filters on truck_id AND shift_id, which no existing index covers.
Two fixes are measured: a composite index on (truck_id, shift_id), and
a rewrite that checks operator_assignment instead of haul_cycle.
Run each EXPLAIN two or three times and compare the last run.
Results and discussion: performance/tuning_notes.md
*/

-- Reset so the "before" measurement is taken without the index
DROP INDEX IF EXISTS haul_cycle_truck_id_shift_id_idx;

-- Before: expect a Hash Anti Join fed by a Seq Scan of every partition,
-- hashing all ~150,000 rows
EXPLAIN (ANALYZE, BUFFERS)
SELECT tr.equipment_id, sh.shift_id
FROM equipment tr
INNER JOIN equipment_model em ON tr.model_id = em.model_id
CROSS JOIN shift sh
WHERE em.equipment_type = 'haul_truck'
  AND NOT EXISTS (
      SELECT 1 FROM haul_cycle hc
      WHERE hc.truck_id = tr.equipment_id AND hc.shift_id = sh.shift_id);

-- Fix 1: composite index. VACUUM updates the visibility map so PostgreSQL
-- can answer from the index alone (Index Only Scan, Heap Fetches: 0).
-- In DBeaver, VACUUM needs auto-commit mode.
CREATE INDEX IF NOT EXISTS haul_cycle_truck_id_shift_id_idx
    ON haul_cycle (truck_id, shift_id);
VACUUM ANALYZE haul_cycle;

-- After fix 1: expect Index Only Scans and far fewer buffers, but the
-- same ~150,000 rows still hashed, so time improves only modestly
EXPLAIN (ANALYZE, BUFFERS)
SELECT tr.equipment_id, sh.shift_id
FROM equipment tr
INNER JOIN equipment_model em ON tr.model_id = em.model_id
CROSS JOIN shift sh
WHERE em.equipment_type = 'haul_truck'
  AND NOT EXISTS (
      SELECT 1 FROM haul_cycle hc
      WHERE hc.truck_id = tr.equipment_id AND hc.shift_id = sh.shift_id);

-- Cost of fix 1: disk space used by the composite indexes
SELECT pg_size_pretty(SUM(pg_relation_size(indexname::regclass))) AS index_size
FROM pg_indexes
WHERE indexname LIKE 'haul_cycle%truck_id_shift_id_idx';

-- Fix 2, step 1: prove operator_assignment holds exactly the truck/shift
-- pairs that have cycles. Both counts must be 0 before relying on it.
SELECT
    (SELECT COUNT(*)
     FROM operator_assignment oa
     WHERE NOT EXISTS (
         SELECT 1 FROM haul_cycle hc
         WHERE hc.truck_id = oa.equipment_id AND hc.shift_id = oa.shift_id)
    ) AS assignments_without_cycles,
    (SELECT COUNT(*)
     FROM (SELECT DISTINCT truck_id, shift_id FROM haul_cycle) d
     WHERE NOT EXISTS (
         SELECT 1 FROM operator_assignment oa
         WHERE oa.equipment_id = d.truck_id AND oa.shift_id = d.shift_id)
    ) AS cycles_without_assignment;

-- Fix 2, step 2: the rewrite. Expect ~7,100 rows hashed instead of
-- ~150,000, and the same 96 result rows.
EXPLAIN (ANALYZE, BUFFERS)
SELECT tr.equipment_id, sh.shift_id
FROM equipment tr
INNER JOIN equipment_model em ON tr.model_id = em.model_id
CROSS JOIN shift sh
WHERE em.equipment_type = 'haul_truck'
  AND NOT EXISTS (
      SELECT 1 FROM operator_assignment oa
      WHERE oa.equipment_id = tr.equipment_id AND oa.shift_id = sh.shift_id);

-- Decision: the composite index is not kept (see tuning_notes.md).
-- Drop it to leave the database as it was.
DROP INDEX IF EXISTS haul_cycle_truck_id_shift_id_idx;

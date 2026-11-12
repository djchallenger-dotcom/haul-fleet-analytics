# Query Tuning Notes

Each exercise follows the same method: measure a realistic query with `EXPLAIN (ANALYZE, BUFFERS)`, identify why it does more work than necessary, make one change, and measure again. Scripts that reproduce every measurement are in this folder.

**How measurements were taken:** PostgreSQL 16 in Docker on a Windows laptop. Each `EXPLAIN` was run two or three times and the last run recorded, since the first run includes warm-up time. Execution times vary between runs and machines; buffer counts (8 kB pages read) describe how much work a query does and stay stable, so they are the primary comparison.

## Exercise 1: Indexing a frequent filter column

**Script:** `01_operator_index.sql`

**Scenario.** A supervisor pulls one operator's production by shift. `haul_cycle` (about 150,000 rows in seven monthly partitions) is indexed on `truck_id` and `shift_id`, but not on `operator_id`.

```sql
SELECT shift_id, COUNT(*) AS cycles, SUM(payload_tonnes) AS tonnes
FROM haul_cycle
WHERE operator_id = 71
GROUP BY shift_id;
```

**Before.** PostgreSQL ran a sequential scan on every partition, reading each row and discarding all but about 1 in 90. Roughly 148,900 rows were read and thrown away to return 1,691.

**Change.** One index on the partitioned parent table, which PostgreSQL automatically creates on every partition:

```sql
CREATE INDEX haul_cycle_operator_id_idx ON haul_cycle (operator_id);
```

**After.** Each partition switched to a bitmap index scan: the index locates operator 71's rows, then only the table pages holding them are read. In January, for example, those rows sit on 16 of the partition's 400 pages.

| | Before | After | Change |
|---|---|---|---|
| Plan | Seq Scan on 7 partitions | Bitmap Index Scan on 7 partitions | |
| Rows read and discarded | ~148,900 | 0 | |
| Buffers (8 kB pages) | 2,348 | 114 | 95% fewer |
| Execution time | 11.2 ms | 1.7 ms | about 6.5x faster |

PostgreSQL chose a bitmap scan rather than a plain index scan because the matching rows are scattered across many pages. Sorting row locations by page first means each page is read only once.

**Cost.** The new indexes take 1,176 kB in total, about 6% of the size of the table itself (about 18 MB). Every inserted cycle must now also update this index, which adds a small amount of write overhead; that was not measured here.

**Conclusion.** Pages read fell by a factor of 20, while time fell by about 6.5. The gap exists because the whole table fits in memory, so reading a page costs little. On a production-size table read from disk, page reads dominate and the improvement would be much closer to the 20x reduction in work. For a column that reports filter on frequently, the trade of about 6% extra storage is clearly worth it.

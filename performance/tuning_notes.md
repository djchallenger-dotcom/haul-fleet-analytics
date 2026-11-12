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

## Exercise 2: Partition pruning, and a boundary bug it exposed

**Script:** `02_partition_pruning.sql`

**Scenario.** Total tonnes per truck for March. `haul_cycle` is partitioned by month on `load_start_ts`. "March" could be defined by when cycles were loaded or when they were dumped; the two timestamps are minutes apart, so both definitions return about 25,925 cycles, but they perform very differently.

```sql
-- Version A: filter on dump_end_ts (not the partition key)
WHERE dump_end_ts >= '2026-03-01 00:00-07' AND dump_end_ts < '2026-04-01 00:00-07'

-- Version B: filter on load_start_ts (the partition key)
WHERE load_start_ts >= '2026-03-01 00:00-07' AND load_start_ts < '2026-04-01 00:00-07'
```

**Version A cannot prune.** PostgreSQL has no way to know which partitions hold March dump times, so it scans all seven. Five of them return no rows after reading every page, and the planner brings in parallel workers just to get through the volume.

**Version B should read one partition but read two.** The plan scanned both March and April. Inspecting the partition bounds showed why: the schema created partitions from plain dates, which PostgreSQL interpreted in the session time zone (UTC). Every partition therefore began at midnight UTC, which is 5 PM the previous day at the mine. A query for March in mine time ran 7 hours past the end of the March partition and into April.

**Fix.** The partition boundaries were redefined as midnight in `America/Phoenix`, so each partition matches a reporting month (see the partition loop in `schema/postgres/schema.sql`). The database was rebuilt from the same seed, so every query result elsewhere in the project is unchanged; only where rows are stored moved.

| | Version A (dump_end_ts) | Version B, before fix | Version B, after fix |
|---|---|---|---|
| Partitions scanned | 7 | 2 | 1 |
| Rows read and discarded | ~124,700 | ~24,950 | 0 |
| Buffers (8 kB pages) | 2,366 | ~800 | 399 |
| Execution time | 13.2 ms | ~11 ms | 8.6 ms |

**Reading the result.** Filtering on the partition key cut pages read by a factor of six. Execution time improved less, about 1.5 times, because Version A ran on three parallel processes while Version B used one; the parallel plan spends more total CPU to finish sooner. Pages read is the fairer measure of work, and on a table too large for memory it is what dominates.

**Takeaways.**

- Filter on the partition key whenever the business definition allows it. For monthly reporting, defining the month by load time rather than dump time is a reasonable choice, and it lets PostgreSQL skip every other month.
- Partition boundaries on a `timestamptz` column must be written with an explicit time zone. Plain dates silently take on the session's zone, which differs between a container (UTC) and a desktop client (local time).
- The bug produced correct results and only showed up in the query plan. Reading `EXPLAIN` output on queries that already look right is how problems like this get found.

## Exercise 3: Composite index vs. query rewrite

**Script:** `03_composite_index.sql`

**Scenario.** The idle-shift query in `queries/04_downtime_gaps.sql` checks all 7,240 truck/shift pairs for haul cycles with `NOT EXISTS`. The inner lookup filters on `truck_id` and `shift_id` together, which no existing index covers. PostgreSQL answers it with a hash anti join: it reads every row of `haul_cycle`, builds a hash table of all 150,584 truck/shift values, and probes it once per pair.

**Fix 1: composite index.** An index on `(truck_id, shift_id)` contains every column the lookup needs, so after `VACUUM ANALYZE` PostgreSQL switched each partition to an index-only scan (`Heap Fetches: 0`, meaning the table itself was never read).

**Fix 2: query rewrite.** The question is only whether each truck/shift pair had any cycles, and `operator_assignment` already holds exactly one row per pair that did. A check in both directions confirmed the two tables agree (0 mismatches each way), so the anti-join can run against `operator_assignment` instead.

| | Original | Fix 1: composite index | Fix 2: rewrite |
|---|---|---|---|
| Rows hashed | 150,584 | 150,584 | 7,144 |
| Hash table memory | 7,931 kB | 7,931 kB | 344 kB |
| Buffers (8 kB pages) | 2,355 | 168 | 58 |
| Execution time | 45.0 ms | 35.9 ms | ~4 ms |
| Result rows | 96 | 96 | 96 |

**Why the index helped less than expected.** The index cut pages read by 93%, but time by only 20%. Splitting the plan's timings shows why: reading the rows fell from 21.3 ms to 16.1 ms, while building the hash table stayed at about 17 to 19 ms either way. Every one of the 150,584 rows still had to be produced and hashed, and that CPU work is untouched by an index. With the table already in memory, reading pages was never the bottleneck.

**Why the rewrite won.** It did not make the same work cheaper; it removed most of the work. Hashing 7,144 rows instead of 150,584 made the query about 11 times faster than the original, with no new index and no extra storage.

**Decisions.**

- **The composite index is not kept.** It costs 1,288 kB and adds write overhead to every cycle inserted, for a modest gain that the rewrite exceeds. The script drops it at the end.
- **`04_downtime_gaps.sql` keeps the original query.** `haul_cycle` is the source of truth for whether a truck worked a shift, and the query states that directly. `operator_assignment` matches it in this data, but only because of how assignments are recorded; if that ever changed, the rewrite would silently return wrong results. The rewrite is documented here as the faster option, valid as long as the equivalence check passes.

**Takeaway.** Before adding an index, check where a query's time actually goes. When a query needs one fact per group, a table that already stores one row per group usually beats any index on the detail table.

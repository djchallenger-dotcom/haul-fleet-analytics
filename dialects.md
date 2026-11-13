# PostgreSQL vs. SQL Server: Dialect Notes

The project was built in PostgreSQL 16, then the schema and six representative queries were ported to SQL Server 2022 (T-SQL). Both databases hold identical data, copied with `data/load_mssql.py`, so every ported query was checked against the PostgreSQL result.

The six queries were chosen to cover the most dialect differences, not for their analysis. Each ported file in `queries/mssql/` explains its specific changes; this document summarizes them.

| Ported query | Main differences |
|---|---|
| `01_fleet_kpis.sql` Q1: monthly tonnes | No `FILTER`; Windows time zone names; `DATETRUNC` |
| `01_fleet_kpis.sql` Q3: availability | `DATEDIFF` boundary counting; `GREATEST` / `LEAST` |
| `02_cycle_time_analysis.sql` Q1: route percentiles | `PERCENTILE_CONT` is window-only; integer `AVG`; sub-second `DATEDIFF` |
| `03_shift_comparison.sql` Q3: experience | Years of service; no `CORR`; no `GROUP BY` alias |
| `04_downtime_gaps.sql` Q1, Q2: idle stretches | `STRING_AGG` ordering; `+` vs `\|\|`; mostly portable |
| `05_maintenance_tree.sql` Q1, Q2: component tree | Recursive CTE rules; no subquery inside aggregates |

## Differences that give wrong answers without an error

These matter most, because the query runs and returns plausible numbers.

**`DATEDIFF` counts boundaries crossed, not elapsed time.** `DATEDIFF(hour, '10:59', '11:01')` returns 1, and `DATEDIFF(hour, '10:01', '10:59')` returns 0. The same holds at every unit, including seconds: `DATEDIFF(second, ...)` ignores fractions of a second. The generated timestamps have microsecond precision, so measuring cycle times in seconds put each cycle off by up to a second. That was enough to change one operator-experience average in the fourth decimal place and tip it across a rounding boundary (1.035 instead of 1.036). Measuring cycle minutes as `DATEDIFF_BIG(microsecond, start, end) / 60000000.0` made the results identical to PostgreSQL at six decimal places. `DATEDIFF_BIG` is required: `DATEDIFF` returns an `int`, which overflows for durations over about 35.8 minutes in microseconds. For durations measured in hours, such as downtime, seconds are precise enough and the results match after rounding.

The same rule breaks ages and tenure: `DATEDIFF(year, '2015-12-31', '2026-01-01')` returns 11 for just over 10 years of service, so the experience query subtracts a year when the anniversary has not been reached. PostgreSQL's `EXTRACT(EPOCH FROM ...)` and `age()` measure actual elapsed time.

**`AVG` of an integer returns an integer in SQL Server.** PostgreSQL returns a decimal. `AVG(DATEDIFF(...))` silently drops the fraction, so values are made decimal before averaging, and integers are cast to `float` before statistical calculations.

**Integer division truncates in both databases,** but `DATEDIFF` returns an integer where PostgreSQL's epoch arithmetic returns a decimal, so the trap appears in SQL Server code that was safe in PostgreSQL. Dividing by a decimal literal (`3600.0`, `60000000.0`) avoids it.

**Comparing results across databases.** A difference in the third decimal place looked like floating-point rounding at first, but checking at six decimal places showed the two databases agreeing only to three, which is too large for float noise. That pointed to the real cause, the second-level `DATEDIFF`. When results differ slightly, comparing at higher precision shows whether the gap is rounding noise or a real calculation difference.

## Queries

| PostgreSQL | SQL Server | Notes |
|---|---|---|
| `SUM(x) FILTER (WHERE cond)` | `SUM(CASE WHEN cond THEN x END)` | Non-matching rows become NULL, which `SUM` skips |
| `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x)` as an aggregate | Same, plus `OVER (PARTITION BY ...)` | Window function only; see below |
| `CORR(x, y)` | No equivalent | Calculated as `(AVG(x*y) - AVG(x)*AVG(y)) / (STDEVP(x)*STDEVP(y))` |
| `STDDEV(x)` | `STDEV(x)`; `STDEVP(x)` for the population version | |
| `STRING_AGG(x, ', ' ORDER BY y)` | `STRING_AGG(x, ', ') WITHIN GROUP (ORDER BY y)` | Ordering moves outside the call |
| `a \|\| b` | `a + b` | Both return NULL if either part is NULL; `CONCAT()` treats NULL as empty |
| `REPEAT(s, n)` | `REPLICATE(s, n)` | |
| `x::date`, `x::numeric` | `CAST(x AS date)` | |
| `GROUP BY alias` | Repeat the expression, or compute it in a CTE | `ORDER BY alias` works in both |
| `DATE_TRUNC('month', ts, 'America/Phoenix')` | `DATETRUNC(month, ts AT TIME ZONE 'US Mountain Standard Time')` | Unquoted date part; no time zone argument |
| `ts AT TIME ZONE 'America/Phoenix'` | `ts AT TIME ZONE 'US Mountain Standard Time'` | Windows zone names; returns `datetimeoffset`, not a local timestamp |
| `EXTRACT(EPOCH FROM end - start)` | `DATEDIFF(second, start, end)`, or `DATEDIFF_BIG(microsecond, ...)` for sub-second precision | Note the argument order |
| `GREATEST`, `LEAST` | Same | New in SQL Server 2022; earlier versions need `CASE` |
| `ROUND(x, 0)` | Same | SQL Server keeps the decimal places (`1776967.0`); cast to `decimal(p,0)` for whole numbers |
| `COALESCE` | Same (`ISNULL` also exists) | `COALESCE` used throughout because it is standard and identical in both |
| `'infinity'::timestamptz` | No equivalent | `'9999-12-31'` stands in for an open end |

**`PERCENTILE_CONT` is the most surprising difference.** In PostgreSQL it is an aggregate: it works with `GROUP BY` and returns one value per group. In SQL Server it is only a window function: it requires `OVER (PARTITION BY ...)`, returns the percentile on every row, and cannot be combined with `GROUP BY` in the same `SELECT`. The ported queries calculate percentiles on every row in a CTE, then collapse the rows with `SELECT DISTINCT` or with `MAX()` inside a `GROUP BY`, since the value is identical on every row of a group.

**Aggregates cannot contain subqueries in SQL Server.** `SUM(COALESCE(end_ts, (SELECT MAX(end_ts) FROM shift)) - start_ts)` is valid PostgreSQL but fails in SQL Server. The fallback value moves into a one-row CTE that is cross-joined.

**Recursive CTEs** port with three changes:

- SQL Server uses plain `WITH` and rejects the `RECURSIVE` keyword.
- Column types must match exactly between the anchor and the recursive part. A path built by concatenation is cast to the same `nvarchar(1000)` in both halves; PostgreSQL only needed the anchor cast to `text`.
- SQL Server stops after 100 levels of recursion by default (`OPTION (MAXRECURSION n)` changes this). PostgreSQL has no default limit.

**What ported unchanged:** `NOT EXISTS` anti-joins, `ROW_NUMBER()` and the gaps-and-islands technique, `RANK`, `HAVING`, `CROSS JOIN`, `LEFT JOIN` logic, `COUNT(column)` vs `COUNT(*)`, ordering by an aggregate, and the interval-overlap test. Standard SQL carries over well; the differences cluster around dates, statistics, and string handling.

## Schema

| PostgreSQL | SQL Server | Notes |
|---|---|---|
| `GENERATED ALWAYS AS IDENTITY` | `IDENTITY(1,1)` | `PRIMARY KEY` must still be declared |
| `text` | `nvarchar(n)` | Indexed and unique columns need a length; `nvarchar(max)` cannot be indexed |
| `timestamptz` | `datetimeoffset` | `datetimeoffset` stores the offset with each value |
| `numeric(p,s)` | `decimal(p,s)` | Synonyms; `numeric` also works in SQL Server |
| `UNIQUE NULLS NOT DISTINCT (a, b)` | `UNIQUE (a, b)` | Opposite defaults: SQL Server treats NULLs as equal in unique constraints, PostgreSQL treats them as distinct |
| `CREATE EXTENSION btree_gist` | Not needed | No exclusion constraints to support |
| `DROP ... IF EXISTS` for all objects | `IF EXISTS (SELECT ... FROM sys.partition_schemes ...)` | No `IF EXISTS` for partition functions and schemes |

**Exclusion constraints have no SQL Server equivalent.** PostgreSQL used them to block overlapping time ranges for the same truck or operator. The port handles the two cases differently:

- **Operator assignments** always cover one whole shift, so `UNIQUE (shift_id, equipment_id)` and `UNIQUE (shift_id, operator_id)` enforce the same rule. This would not catch overlaps between partial-shift assignments; it is valid because of how assignments are recorded.
- **Downtime events** have arbitrary start and end times, so a trigger enforces the rule. It joins the special `inserted` table to existing events using the overlap test and raises an error with `THROW`, which rolls back the statement. It checks all new rows at once, so bulk loads run it once per statement. Testing it by inserting an overlapping event confirmed the rejection.

**Partitioning works on different models.**

- In PostgreSQL, the table declares `PARTITION BY RANGE`, and each partition is a real table created separately, plus a `DEFAULT` partition for anything outside the defined ranges.
- In SQL Server, a partition function defines the boundary values, a partition scheme maps the resulting partitions to storage, and the table is created `ON` the scheme. Partitions are internal divisions of one table, never created individually. With `RANGE RIGHT`, each boundary value starts the partition to its right, so seven monthly boundaries create eight partitions; the first and last catch anything outside the period, as PostgreSQL's default partition does.
- In both, the primary key must include the partitioning column, and boundaries are written with an explicit `-07:00` offset so partitions match mine-local months (see `performance/tuning_notes.md`, Exercise 2).

**Batches.** `CREATE TRIGGER` must be the only statement in its batch, so the schema script uses `GO` separators. `GO` is a client command, not SQL; the server never sees it.

**Text types.** `varchar` stores single-byte characters and `nvarchar` stores Unicode. The schema uses `nvarchar` throughout, so names with accented or non-Latin characters would be stored correctly.

## Loading the data

`data/load_mssql.py` copies every table from PostgreSQL with `pyodbc`:

- `SET IDENTITY_INSERT ... ON` allows the original ID values, so both databases match row for row.
- `pyodbc` drops the time zone from Python datetimes, so timestamps are sent as ISO 8601 strings with an explicit offset, which SQL Server converts to `datetimeoffset`.
- With `fast_executemany`, `pyodbc` sizes text and decimal parameters from the first row of a batch, so a longer string or a decimal with more digits later would fail. The script reads each column's size from SQL Server and declares it with `setinputsizes`.
- Tables are cleared children first and loaded parents first, so foreign keys always resolve.

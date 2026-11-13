/*
queries/mssql/02_cycle_time_analysis.sql
T-SQL port of selected queries from queries/02_cycle_time_analysis.sql:
Q1 (route percentiles). Comments focus on what differs from the
PostgreSQL version; see the original for the full analysis and
findings. Dialect differences are summarized in dialects.md.
*/

/*
Q1: Typical and slow cycle times per haul route (T-SQL port)
Changes from PostgreSQL:
- PERCENTILE_CONT is only a window function in SQL Server; it cannot
  be used as an aggregate with GROUP BY. Percentiles are added to every
  cycle row with OVER (PARTITION BY route), then rows are grouped by
  route. The percentile is identical on every row of a route, so MAX()
  simply returns it.
- Cycle minutes use DATEDIFF_BIG(microsecond, ...) / 60000000.0.
  DATEDIFF counts unit boundaries crossed, so DATEDIFF(second, ...)
  would drop fractions of a second from microsecond timestamps.
  DATEDIFF_BIG is needed because DATEDIFF returns an int, which
  overflows for durations over about 35.8 minutes in microseconds.
- AVG of an integer returns an integer in SQL Server (PostgreSQL
  returns a decimal); dividing by a decimal literal makes cycle
  minutes decimal before they are averaged.
- PERCENTILE_CONT returns float, which ROUND accepts directly; no cast
  is needed.
Results match the PostgreSQL version.
*/

WITH cycles AS (
    SELECT
        hc.load_location_id,
        hc.dump_location_id,
        DATEDIFF_BIG(microsecond, hc.arrive_shovel_ts, hc.cycle_end_ts) / 60000000.0 AS cycle_minutes
    FROM haul_cycle hc
),
cycles_with_percentiles AS (
    SELECT
        load_location_id,
        dump_location_id,
        cycle_minutes,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cycle_minutes)
            OVER (PARTITION BY load_location_id, dump_location_id) AS median_minutes,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY cycle_minutes)
            OVER (PARTITION BY load_location_id, dump_location_id) AS p90_minutes
    FROM cycles
),
base_stats AS (
    SELECT
        loadloc.name AS load_location,
        dumploc.name AS dump_location,
        COUNT(*) AS cycle_count,
        AVG(c.cycle_minutes) AS average_minutes,
        MAX(c.median_minutes) AS median_minutes,   -- same value on every row of the route
        MAX(c.p90_minutes) AS p90_minutes
    FROM cycles_with_percentiles c
    INNER JOIN location loadloc ON c.load_location_id = loadloc.location_id
    INNER JOIN location dumploc ON c.dump_location_id = dumploc.location_id
    GROUP BY loadloc.name, dumploc.name
)
SELECT
    load_location,
    dump_location,
    cycle_count,
    ROUND(average_minutes, 2) AS average_minutes,
    ROUND(median_minutes, 2) AS median_minutes,
    ROUND(p90_minutes, 2) AS p90_minutes,
    ROUND(p90_minutes / median_minutes, 2) AS p90_to_median
FROM base_stats
ORDER BY p90_to_median DESC;
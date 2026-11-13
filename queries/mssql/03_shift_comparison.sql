/*
queries/mssql/03_shift_comparison.sql
T-SQL port of selected queries from queries/03_shift_comparison.sql:
Q3 (operator experience). Comments focus on what differs from the
PostgreSQL version; see the original for the full analysis and
findings. Dialect differences are summarized in dialects.md.
*/

/*
Q3: Do more experienced operators perform better? (T-SQL port)
Changes from PostgreSQL:
- Cycle minutes use DATEDIFF_BIG(microsecond, ...) / 60000000.0.
  DATEDIFF counts unit boundaries crossed, so DATEDIFF(second, ...)
  drops fractions of a second; with microsecond timestamps, that was
  enough to change one band's average in the fourth decimal place.
  DATEDIFF_BIG is needed because DATEDIFF returns an int, which
  overflows for durations over about 35.8 minutes in microseconds.
- Medians use PERCENTILE_CONT as a window function (the only form SQL
  Server supports), with SELECT DISTINCT keeping one row per route and
  shift type.
- Years of service: DATEDIFF(year, ...) counts year boundaries crossed,
  not completed years, so someone hired on 2015-12-31 would count as 11
  years on 2026-01-01. The CASE subtracts 1 when the hire anniversary
  has not yet been reached, matching PostgreSQL's age().
- SQL Server cannot GROUP BY a column alias, so the experience band is
  calculated in a CTE and grouped as an ordinary column.
- There is no CORR function. The correlation is calculated from its
  definition: (AVG(xy) - AVG(x) * AVG(y)) / (STDEVP(x) * STDEVP(y)).
  Years are cast to float first, because AVG of an integer returns an
  integer in SQL Server.
Results match the PostgreSQL version exactly, to six decimal places.
*/

WITH cycles AS (
    SELECT
        hc.operator_id,
        sh.shift_type,
        hc.load_location_id,
        hc.dump_location_id,
        DATEDIFF_BIG(microsecond, hc.arrive_shovel_ts, hc.cycle_end_ts) / 60000000.0 AS cycle_minutes
    FROM haul_cycle hc
    INNER JOIN shift sh ON hc.shift_id = sh.shift_id
),
medians AS (
    SELECT DISTINCT
        shift_type,
        load_location_id,
        dump_location_id,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cycle_minutes)
            OVER (PARTITION BY load_location_id, dump_location_id, shift_type) AS median_minutes
    FROM cycles
),
operator_scores AS (
    SELECT
        c.operator_id,
        COUNT(*) AS cycles,
        AVG(c.cycle_minutes / m.median_minutes) AS performance_index
    FROM cycles c
    INNER JOIN medians m ON c.load_location_id = m.load_location_id
                       AND c.dump_location_id = m.dump_location_id
                       AND c.shift_type = m.shift_type
    GROUP BY c.operator_id
),
operator_years AS (
    SELECT
        os.operator_id,
        os.performance_index,
        DATEDIFF(year, op.hire_date, '2026-01-01')
          - CASE WHEN DATEADD(year, DATEDIFF(year, op.hire_date, '2026-01-01'), op.hire_date) > '2026-01-01'
                 THEN 1 ELSE 0 END AS years_experience
    FROM operator_scores os
    INNER JOIN operator op ON os.operator_id = op.operator_id
),
operator_experience AS (
    SELECT
        operator_id,
        performance_index,
        years_experience,
        CASE
            WHEN years_experience <= 2  THEN '0-2 years'
            WHEN years_experience <= 7  THEN '3-7 years'
            WHEN years_experience <= 12 THEN '8-12 years'
            ELSE '13+ years'
        END AS experience_group
    FROM operator_years
)

SELECT
    experience_group,
    COUNT(*) AS operators,
    ROUND(AVG(performance_index), 3) AS avg_index,
    (SELECT ROUND(
                (AVG(performance_index * CAST(years_experience AS float))
                 - AVG(performance_index) * AVG(CAST(years_experience AS float)))
                / (STDEVP(performance_index) * STDEVP(CAST(years_experience AS float))), 3)
     FROM operator_experience) AS overall_correlation
FROM operator_experience
GROUP BY experience_group
ORDER BY MIN(years_experience);


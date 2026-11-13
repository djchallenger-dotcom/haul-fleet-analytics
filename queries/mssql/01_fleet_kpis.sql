/*
queries/mssql/01_fleet_kpis.sql
T-SQL ports of selected queries from queries/01_fleet_kpis.sql:
Q1 (monthly tonnes) and Q3 (availability). Comments focus on what
differs from the PostgreSQL version; see the original for the full
analysis and findings. Dialect differences are summarized in dialects.md.
*/

/*
Q1: Monthly tonnes by material (T-SQL port)
Changes from PostgreSQL:
- FILTER (WHERE ...) becomes SUM(CASE WHEN ... END); SQL Server has no
  FILTER clause.
- Time zones use Windows names: 'US Mountain Standard Time' is Arizona
  (MST, no DST). Values are converted to mine time before truncating.
- DATETRUNC(month, ...) takes an unquoted date part and no time zone
  argument; CAST(... AS date) replaces ::date.
- GROUP BY repeats the expression; SQL Server does not allow grouping
  by a column alias.
Results match the PostgreSQL version exactly.
*/

SELECT 
    CAST(DATETRUNC(month, hc.dump_end_ts AT TIME ZONE 'US Mountain Standard Time') AS date) AS month_start,
    ROUND(SUM(CASE WHEN hc.material_type = 'ore'   THEN hc.payload_tonnes END), 0) AS ore_tonnes,
    ROUND(SUM(CASE WHEN hc.material_type = 'waste' THEN hc.payload_tonnes END), 0) AS waste_tonnes,
    ROUND(SUM(hc.payload_tonnes), 0) AS total_tonnes
FROM haul_cycle hc
GROUP BY CAST(DATETRUNC(month, hc.dump_end_ts AT TIME ZONE 'US Mountain Standard Time') AS date)
ORDER BY month_start;


/*
Q3: Physical availability per truck (T-SQL port)
Same logic as the PostgreSQL version: maintenance downtime is clipped
to the reporting window, open events run to the window end, and events
entirely outside the window are excluded.
Changes from PostgreSQL:
- Durations use DATEDIFF(second, start, end) / 3600.0 instead of
  EXTRACT(EPOCH FROM end - start) / 3600. DATEDIFF counts unit
  boundaries crossed, not elapsed time, so DATEDIFF(hour, ...) would
  round every event to whole hours; counting seconds avoids that.
  The .0 forces decimal division, since DATEDIFF returns an integer.
- DATEDIFF takes start before end, the reverse of the PostgreSQL
  subtraction (end - start).
- GREATEST and LEAST clip events to the window. Both are new in
  SQL Server 2022; earlier versions would need CASE expressions.
- COALESCE is used rather than SQL Server's ISNULL because it is
  standard SQL and behaves the same in both databases.
Results match the PostgreSQL version exactly.
*/

WITH period AS (
    SELECT
        MIN(start_ts) AS period_start,
        MAX(end_ts)   AS period_end,
        DATEDIFF(second, MIN(start_ts), MAX(end_ts)) / 3600.0 AS calendar_hours
    FROM shift
),
maintenance AS (
    SELECT
        dte.equipment_id,
        SUM(DATEDIFF(second,
                GREATEST(dte.start_ts, p.period_start),
                LEAST(COALESCE(dte.end_ts, p.period_end), p.period_end)
            )) / 3600.0 AS downtime_hours
    FROM downtime_event dte
    CROSS JOIN period p
    WHERE dte.category IN ('planned_maintenance', 'unplanned_maintenance')
      AND dte.start_ts < p.period_end
      AND COALESCE(dte.end_ts, p.period_end) > p.period_start
    GROUP BY dte.equipment_id
)

SELECT 
    eq.equipment_id,
    eq.unit_number,
    ROUND(p.calendar_hours, 0) AS calendar_hours,
    ROUND(COALESCE(m.downtime_hours, 0), 1) AS downtime_hours,
    COALESCE(ROUND((p.calendar_hours - m.downtime_hours) / p.calendar_hours * 100, 1), 100) AS availability
FROM equipment eq
INNER JOIN equipment_model em ON eq.model_id = em.model_id
LEFT JOIN maintenance m ON eq.equipment_id = m.equipment_id
CROSS JOIN period p
WHERE em.equipment_type = 'haul_truck'
ORDER BY availability;


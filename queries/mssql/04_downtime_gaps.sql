/*
queries/mssql/04_downtime_gaps.sql
T-SQL ports of queries/04_downtime_gaps.sql: Q1 (consecutive idle
shifts) and Q2 (causes of each idle stretch). Comments focus on what
differs from the PostgreSQL version; see the original for the full
analysis and findings. Dialect differences are summarized in dialects.md.
*/

/*
Q1: Consecutive idle shifts per truck (T-SQL port)
Ports with almost no changes: NOT EXISTS anti-joins, ROW_NUMBER(), the
gaps-and-islands key, HAVING, and ORDER BY an aggregate are standard SQL
and behave identically in both databases.
Changes from PostgreSQL:
- Time zones use the Windows name 'US Mountain Standard Time'.
- AT TIME ZONE returns a datetimeoffset in SQL Server (the same moment
  shown with a -07:00 offset), whereas PostgreSQL returns a plain
  timestamp in local time. Values are the same; only display differs.
Results match the PostgreSQL version.
*/

WITH trucks AS (
    SELECT 
        eq.equipment_id AS truck_id,
        eq.unit_number
    FROM equipment eq
    INNER JOIN equipment_model eqm ON eq.model_id = eqm.model_id
    WHERE eqm.equipment_type = 'haul_truck'
),
idle_shifts AS (
    SELECT
        tr.truck_id,
        tr.unit_number,
        sh.shift_id,
        sh.start_ts,
        sh.end_ts
    FROM trucks tr 
    CROSS JOIN shift sh
    WHERE NOT EXISTS (
        SELECT 1 FROM haul_cycle hc 
        WHERE hc.truck_id = tr.truck_id AND hc.shift_id = sh.shift_id)
),
islands AS (
    SELECT
        ish.truck_id,
        ish.unit_number,
        ish.shift_id,
        ish.start_ts,
        ish.end_ts,
        ish.shift_id - ROW_NUMBER() OVER (PARTITION BY ish.truck_id ORDER BY ish.shift_id) AS island_key
    FROM idle_shifts ish
)

SELECT 
    isl.truck_id,
    isl.unit_number,
    MIN(isl.start_ts) AT TIME ZONE 'US Mountain Standard Time' AS begin_idle,
    MAX(isl.end_ts) AT TIME ZONE 'US Mountain Standard Time' AS end_idle,
    COUNT(*) AS shift_count
FROM islands isl
GROUP BY isl.truck_id, isl.unit_number, isl.island_key
HAVING COUNT(*) >= 2
ORDER BY shift_count DESC, MIN(isl.start_ts);



/*
Q2: What caused each multi-shift idle stretch? (T-SQL port)
Builds on Q1 exactly as in PostgreSQL; the stretches CTE, overlap join,
LEFT JOINs, and COUNT(column) behave the same way.
Changes from PostgreSQL:
- STRING_AGG ordering goes after the parentheses in a WITHIN GROUP
  clause, as with PERCENTILE_CONT, rather than inside the call.
- Strings concatenate with + instead of ||. Both return NULL when any
  part is NULL, so the COALESCE pattern is unchanged. (SQL Server's
  CONCAT() function would instead treat NULLs as empty strings.)
- Time zones use the Windows name 'US Mountain Standard Time'.
Results match the PostgreSQL version.
*/

WITH trucks AS (
    SELECT 
        eq.equipment_id AS truck_id,
        eq.unit_number
    FROM equipment eq
    INNER JOIN equipment_model eqm ON eq.model_id = eqm.model_id
    WHERE eqm.equipment_type = 'haul_truck'
),
idle_shifts AS (
    SELECT
        tr.truck_id,
        tr.unit_number,
        sh.shift_id,
        sh.start_ts,
        sh.end_ts
    FROM trucks tr 
    CROSS JOIN shift sh
    WHERE NOT EXISTS (
        SELECT 1 FROM haul_cycle hc 
        WHERE hc.truck_id = tr.truck_id AND hc.shift_id = sh.shift_id)
),
islands AS (
    SELECT
        ish.truck_id,
        ish.unit_number,
        ish.shift_id,
        ish.start_ts,
        ish.end_ts,
        ish.shift_id - ROW_NUMBER() OVER (PARTITION BY ish.truck_id ORDER BY ish.shift_id) AS island_key
    FROM idle_shifts ish
),
stretches AS (
    SELECT 
        isl.truck_id,
        isl.unit_number,
        MIN(isl.start_ts) AS stretch_start,
        MAX(isl.end_ts) AS stretch_end,
        COUNT(*) AS shift_count
    FROM islands isl
    GROUP BY isl.truck_id, isl.unit_number, isl.island_key
    HAVING COUNT(*) >= 2
)

SELECT 
    st.truck_id,
    st.unit_number,
    st.stretch_start AT TIME ZONE 'US Mountain Standard Time' AS stretch_start_local,
    st.shift_count,
    COUNT(dte.downtime_id) AS events,
    STRING_AGG(dte.category + COALESCE(' (' + c.name + ')', ''), '; ')
        WITHIN GROUP (ORDER BY dte.start_ts) AS causes
FROM stretches st
LEFT JOIN downtime_event dte ON  dte.equipment_id = st.truck_id
   AND dte.start_ts < st.stretch_end
   AND COALESCE(dte.end_ts, st.stretch_end) > st.stretch_start
LEFT JOIN component c ON c.component_id = dte.component_id
GROUP BY st.truck_id, st.unit_number, st.stretch_start, st.shift_count
ORDER BY st.shift_count DESC, st.stretch_start;


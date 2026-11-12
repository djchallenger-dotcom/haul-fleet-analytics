/*
Q1: When was each truck out of production for consecutive shifts,
and which stretches were longest?
An idle shift is a truck/shift pair with no haul cycles, found with an
anti-join (CROSS JOIN every truck with every shift, then NOT EXISTS
against haul_cycle). Consecutive idle shifts are grouped with the
gaps-and-islands technique: shift_id minus ROW_NUMBER() per truck stays
constant within an unbroken run and changes after each gap, so it acts
as a group key for each stretch. This relies on shift_id running
1-362 with no gaps. HAVING keeps only stretches of 2+ shifts; single
idle shifts are routine.
Finding: 96 idle truck-shifts form 80 stretches, and 69 of those are a
single shift. Only 11 stretches last two shifts or more, and three
reach three or more. The longest is HT-106, out for 5 consecutive
shifts (Feb 18 evening to Feb 21 morning, about 2.5 days). Long
outages are rare, but each one removes a truck for days.
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
    MIN(isl.start_ts) AT TIME ZONE 'America/Phoenix' AS begin_idle,
    MAX(isl.end_ts) AT TIME ZONE 'America/Phoenix' AS end_idle,
    COUNT(*) AS shift_count
FROM islands isl
GROUP BY isl.truck_id, isl.unit_number, isl.island_key
HAVING COUNT(*) >= 2
ORDER BY shift_count DESC, MIN(isl.start_ts);



/*
Q2: What caused each multi-shift idle stretch?
Builds on Q1: the stretches CTE is Q1's result, and each stretch is
LEFT JOINed to downtime events for the same truck that overlap it
(same overlap test as 01_fleet_kpis.sql Q3). LEFT JOINs keep any
stretch with no recorded downtime visible, and keep events without a
component. STRING_AGG combines multiple causes into one column in
time order; COUNT(dte.downtime_id) rather than COUNT(*) so a stretch
with no events would show 0, not 1.
Finding: all 11 stretches are explained, and each traces to a single
unplanned maintenance event. HT-106's 5-shift outage was a brake
failure; the 3-shift outages were hoist cylinders (HT-107) and tires
(HT-103). Planned maintenance never causes a multi-shift outage,
because it is scheduled to fit within a shift. Reducing long outages
is a reliability problem, not a scheduling one.
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
    st.stretch_start AT TIME ZONE 'America/Phoenix' AS stretch_start_local,
    st.shift_count,
    COUNT(dte.downtime_id) AS events,
    STRING_AGG(dte.category || COALESCE(' (' || c.name || ')', ''), '; ' ORDER BY dte.start_ts) AS causes
FROM stretches st
LEFT JOIN downtime_event dte ON  dte.equipment_id = st.truck_id
   AND dte.start_ts < st.stretch_end
   AND COALESCE(dte.end_ts, st.stretch_end) > st.stretch_start
LEFT JOIN component c ON c.component_id = dte.component_id
GROUP BY st.truck_id, st.unit_number, st.stretch_start, st.shift_count
ORDER BY st.shift_count DESC, st.stretch_start;

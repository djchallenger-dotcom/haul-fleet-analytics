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

/*
Q1: How many tonnes of ore and waste did the fleet move each month?
Tonnes count when the truck finishes dumping (dump_end_ts).
Months are bucketed in mine-local time (America/Phoenix, UTC-7,
no DST); the container runs in UTC, so truncating without a time
zone would push late-evening cycles into the next month.
The small July row is the June 30 night shift crossing midnight.
The AT TIME ZONE before ::DATE makes the month label independent
of the client's session time zone.
*/

SELECT 
    (DATE_TRUNC('month', hc.dump_end_ts, 'America/Phoenix') AT TIME ZONE 'America/Phoenix')::DATE AS month,
    ROUND(SUM(hc.payload_tonnes) FILTER (WHERE hc.material_type = 'ore'),0) AS ore_tonnes,
    ROUND(SUM(hc.payload_tonnes) FILTER (WHERE hc.material_type = 'waste'),0) AS waste_tonnes,
    ROUND(SUM(hc.payload_tonnes),0) AS total_tonnes
FROM haul_cycle hc 
GROUP BY (DATE_TRUNC('month', hc.dump_end_ts, 'America/Phoenix') AT TIME ZONE 'America/Phoenix')::DATE
ORDER BY month;



/*
Q2: Where does haul cycle time go, and does it differ between
day and night shift?
Each stage is the gap between consecutive cycle timestamps
(queue -> load -> loaded haul -> dump -> empty return); the five
stages sum to the total cycle time.
Finding: night cycles average X min longer than day (Y vs Z min).
The gap comes from queue, loaded haul, and empty return; load and
dump times are flat because they depend on the shovel and truck
body, not the operator or visibility.
 */

SELECT 
    sh.shift_type AS shift_type,
    ROUND(AVG(EXTRACT(EPOCH FROM(hc.load_start_ts - hc.arrive_shovel_ts))/60), 1) AS queue,
    ROUND(AVG(EXTRACT(EPOCH FROM(hc.load_end_ts - hc.load_start_ts))/60), 1) AS load,
    ROUND(AVG(EXTRACT(EPOCH FROM(hc.dump_start_ts - hc.load_end_ts))/60), 1) AS loaded_haul,
    ROUND(AVG(EXTRACT(EPOCH FROM(hc.dump_end_ts - hc.dump_start_ts))/60), 1) AS dump,
    ROUND(AVG(EXTRACT(EPOCH FROM(hc.cycle_end_ts - hc.dump_end_ts))/60), 1) AS empty_return,
    ROUND(AVG(EXTRACT(EPOCH FROM(hc.cycle_end_ts - hc.arrive_shovel_ts))/60), 1) AS total_cycle_time
FROM haul_cycle hc
INNER JOIN shift sh ON hc.shift_id = sh.shift_id
GROUP BY sh.shift_type
ORDER BY sh.shift_type;


/*
Q3: What was each haul truck's physical availability?
Physical availability = (calendar hours - maintenance hours) / calendar hours.
Only planned and unplanned maintenance count as downtime. Operational
delays and standby don't, because the truck was mechanically ready.
The reporting window runs from the first shift start to the last shift
end. Each downtime event is clipped to that window: events still open
(end_ts NULL) run to the window end, and events crossing either boundary
only count the hours inside it. Events entirely outside are excluded.
Finding: availability ranges from 86.7% (HT-207) to 92.5% (HT-208).
 */

WITH period AS (
    SELECT
        MIN(start_ts) AS period_start,
        MAX(end_ts)   AS period_end,
        EXTRACT(EPOCH FROM (MAX(end_ts) - MIN(start_ts))) / 3600 AS calendar_hours
    FROM shift
),
maintenance AS (
    SELECT
        dte.equipment_id,
        SUM(EXTRACT(EPOCH FROM (
            LEAST(COALESCE(dte.end_ts, p.period_end), p.period_end)
                - GREATEST(dte.start_ts, p.period_start)
           )) / 3600) AS downtime_hours
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



/*
Q4: Which haul trucks are most productive?
Productivity = tonnes moved per operating hour, where operating hours
is time spent in haul cycles (arrive at shovel to back at shovel).
Downtime and shift changes are excluded, so this measures how well a
truck works while running, not how often it runs (see Q3).
Two ranks: fleet_rank compares all trucks; model_rank compares each
truck only against the same model, since payload capacity differs.
Finding: fleet rank is decided by model. All 930Es (290 t) rank 1-8
at ~584-589 t/h; all 793Fs (227 t) rank 9-20 at ~459-463 t/h.
Within each model the spread is only ~1%, because trucks rotate
between shovels and operators each shift. Variation between
operators is examined in 03_shift_comparison.sql.
*/

WITH truck_totals AS (
    SELECT 
        hc.truck_id,
        eq.unit_number,
        eqm.manufacturer,
        eqm.model_name,
        eqm.payload_capacity_tonnes,
        SUM(hc.payload_tonnes) AS total_tonnes,
        EXTRACT(EPOCH FROM(SUM(hc.cycle_end_ts - hc.arrive_shovel_ts )))/3600 AS operating_hours
    FROM haul_cycle hc
    INNER JOIN equipment eq ON hc.truck_id = eq.equipment_id
    INNER JOIN equipment_model eqm ON eq.model_id = eqm.model_id
    WHERE eqm.equipment_type = 'haul_truck'
    GROUP BY hc.truck_id, 
        eq.unit_number, 
        eqm.manufacturer, 
        eqm.model_name, 
        eqm.payload_capacity_tonnes
)

SELECT
    tt.truck_id,
    tt.unit_number,
    tt.manufacturer,
    tt.model_name,
    tt.payload_capacity_tonnes,
    ROUND(tt.total_tonnes, 0) AS total_tonnes,
    ROUND(tt.operating_hours, 0) AS operating_hours,
    ROUND(tt.total_tonnes / tt.operating_hours, 1) AS tonnes_per_hour,
    RANK() OVER (ORDER BY tt.total_tonnes/tt.operating_hours DESC) AS fleet_rank,
    RANK() OVER (PARTITION BY tt.model_name ORDER BY tt.total_tonnes/tt.operating_hours DESC) AS model_rank
FROM truck_totals tt
ORDER BY fleet_rank;

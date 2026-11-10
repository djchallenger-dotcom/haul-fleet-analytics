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
ORDER BY sh.shift_type
;

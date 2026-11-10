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

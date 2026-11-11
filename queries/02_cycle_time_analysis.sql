/*
Q1: How long are typical and slow cycles on each haul route, and
which routes are least predictable?
A route is a load location / dump location pair. Median and p90
show the typical and slow ends of the distribution; p90 / median
measures spread independent of route length.
Finding: the shortest routes are proportionally the least
predictable (South Pit Face -> West Waste Dump: median 21.9 min,
p90 27.1, ratio 1.24), while the long crusher haul is the most
consistent (ratio 1.17). Shovel queue time varies by about the same
amount on every route, so it makes up a larger share of short
cycles. On every route the average sits above the median, a
right-skewed distribution caused by a tail of slow cycles.
*/

WITH base_stats AS (
    SELECT 
        loadloc.name AS load_location,
        dumploc.name AS dump_location,
        COUNT(*) AS cycle_count,
        EXTRACT(EPOCH FROM(AVG(hc.cycle_end_ts - hc.arrive_shovel_ts)))/60 AS average_minutes,
        (PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (hc.cycle_end_ts - hc.arrive_shovel_ts)) / 60
            ))::NUMERIC
             AS median_minutes,
        PERCENTILE_CONT(0.9) WITHIN GROUP(
            ORDER BY EXTRACT(EPOCH FROM (hc.cycle_end_ts - hc.arrive_shovel_ts)) / 60
            )::NUMERIC
            AS p90_minutes
    FROM haul_cycle hc
    INNER JOIN location loadloc ON hc.load_location_id = loadloc.location_id
    INNER JOIN location dumploc ON hc.dump_location_id = dumploc.location_id
    GROUP BY 
        loadloc.name, 
        dumploc.name
)

SELECT
    load_location,
    dump_location,
    cycle_count,
    ROUND(average_minutes, 2) AS average_minutes,
    ROUND(median_minutes, 2) AS median_minutes,
    ROUND(p90_minutes, 2) AS p90_minutes,
    ROUND(p90_minutes/median_minutes, 2) AS p90_to_median
FROM base_stats
ORDER BY p90_to_median DESC;



/*
Q2: How much time passes between a truck's consecutive cycles,
and where does that unrecorded time go?
LAG() looks up the previous cycle's end time for the same truck;
the gap is the time from that cycle ending to the next one starting.
Each truck's first cycle has no previous cycle and is excluded.
Finding: 95% of cycles (141,978) follow the previous one with no gap.
The 30 min to 2 h bucket (7,291 gaps, ~6,500 h) is mostly shift
changes, since every shift change leaves at least 35 minutes between
cycles. The over 2 h bucket holds only 1,243 gaps but ~9,700 h,
about 60% of all lost time; these are downtime events, often
spanning more than one shift. A small number of long stoppages
costs more than all routine interruptions combined.
*/

WITH cycles AS (
    SELECT
        hc.truck_id,
        hc.shift_id,
        hc.arrive_shovel_ts,
        LAG(hc.cycle_end_ts) OVER (PARTITION BY hc.truck_id ORDER BY hc.arrive_shovel_ts) AS prev_cycle_end
    FROM haul_cycle hc 
),
time_gaps AS (
    SELECT 
        arrive_shovel_ts,
        prev_cycle_end,
        EXTRACT(EPOCH FROM(arrive_shovel_ts - prev_cycle_end))/60 AS gap_minutes
    FROM cycles
),
time_buckets AS (
    SELECT 
    gap_minutes,
    CASE WHEN gap_minutes = 0 THEN 'continuous'
         WHEN gap_minutes < 30 THEN 'under 30 min'
         WHEN gap_minutes < 120 THEN '30 min to 2 hours'
         ELSE 'over 2 hours'
         END AS gap_bucket
    FROM time_gaps
    WHERE prev_cycle_end IS NOT NULL
)

SELECT
    gap_bucket,
    COUNT(*) AS gap_count,
    ROUND(SUM(gap_minutes) / 60, 1) AS total_gap_hours
FROM time_buckets
GROUP BY gap_bucket
ORDER BY MIN(gap_minutes);


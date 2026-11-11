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

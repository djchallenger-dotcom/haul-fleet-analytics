/*
Q1: Which operators are fastest, compared fairly?
Each cycle is divided by the median cycle time for its route and
shift type, then averaged per operator (1.00 = typical; lower is
faster). Normalizing matters because crews never change shifts:
A and C always work days, B and D always work nights, and night
cycles run ~8% slower. Raw averages would penalize night crews.
Finding: the performance index ranges from 0.956 to 1.114, a spread
of about 16%, against ~1% between trucks of the same model (01, Q4).
Operator technique matters far more than the truck. The fastest
operators also complete ~20% more cycles over the same period.
Night-crew operators appear in the top quartile, which shows the
normalization is working.
*/

WITH cycles AS (    
    SELECT 
        hc.operator_id,
        sh.shift_type,
        hc.load_location_id,
        hc.dump_location_id,
        EXTRACT(EPOCH FROM (hc.cycle_end_ts - hc.arrive_shovel_ts)) / 60 AS cycle_minutes
    FROM haul_cycle hc
    INNER JOIN shift sh ON hc.shift_id = sh.shift_id
),
medians AS (
    SELECT
        shift_type,
        load_location_id,
        dump_location_id,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cycle_minutes) AS median_minutes
    FROM cycles
    GROUP BY shift_type, load_location_id, dump_location_id
),
operator_scores AS (
    SELECT 
        c.operator_id,
        COUNT(*) AS cycles,
        AVG(c.cycle_minutes / m.median_minutes) AS performance_index
    FROM cycles c
    INNER JOIN medians m ON c.load_location_id = m.load_location_id
                       AND c.dump_location_Id = m.dump_location_id
                       AND c.shift_type = m.shift_type
    GROUP BY c.operator_id
)

SELECT
    op.employee_number,
    op.last_name || ', ' || op.first_name AS operator,
    op.crew,
    opsc.cycles,
    ROUND(opsc.performance_index::NUMERIC, 3) AS performance_index,
    RANK() OVER (ORDER BY opsc.performance_index) AS rank,
    NTILE(4) OVER (ORDER BY opsc.performance_index) AS quartile
FROM operator op
INNER JOIN operator_scores opsc ON op.operator_id = opsc.operator_id
ORDER BY rank;

/*
03_shift_comparison.sql
Operator and crew performance, compared fairly: cycles are normalized
against the median for their route and shift type, so operators and
crews on different routes and shifts can be ranked on equal terms.
*/

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
                       AND c.dump_location_id = m.dump_location_id
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



/*
Q2: How do the four crews compare, and how consistent is each crew
from shift to shift?
Two levels of aggregation: each shift is summarized first (total
tonnes, performance index as in Q1), then shifts are summarized by crew.
Finding: day crews A and C move ~103,500 t per shift; night crews
move less, as expected. But crews B and D work identical night
conditions, yet D moves ~3,300 t more per shift (97,400 vs 94,100)
because its operators cycle faster (index 1.016 vs 1.038). D's index
also beats both day crews.
All crews are equally consistent: the index varies by under 1% from
shift to shift, while tonnes vary ~6-7% (tonnes_cv_pct). Those swings
come from how many trucks are down in a given shift, not from the
crew's speed.
 */

WITH cycles AS (    
    SELECT 
        hc.shift_id,
        sh.shift_type,
        sh.crew,
        hc.load_location_id,
        hc.dump_location_id,
        hc.payload_tonnes,
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
shift_scores AS (
    SELECT
        c.crew,
        c.shift_type,
        SUM(c.payload_tonnes) AS total_tonnes,
        AVG(c.cycle_minutes/m.median_minutes) AS performance_index
    FROM cycles c
    INNER JOIN medians m ON c.load_location_id = m.load_location_id
                       AND c.dump_location_id = m.dump_location_id
                       AND c.shift_type = m.shift_type
    GROUP BY c.shift_id, c.crew, c.shift_type
)

SELECT
    sc.crew,
    sc.shift_type,
    COUNT(*) AS shifts_worked,
    ROUND(AVG(sc.total_tonnes), 0) AS avg_tonnes,
    ROUND(STDDEV(sc.total_tonnes), 0) AS stddev_tonnes,
    ROUND(AVG(sc.performance_index)::NUMERIC, 3) AS avg_index,
    ROUND(STDDEV(sc.performance_index)::NUMERIC, 3) AS stddev_index,
    ROUND(100 * STDDEV(sc.total_tonnes) / AVG(sc.total_tonnes), 1) AS tonnes_cv_pct  -- coefficient of variation
FROM shift_scores sc
GROUP BY sc.crew, sc.shift_type
ORDER BY sc.crew;



/*
Q3: Do more experienced operators perform better?
Reuses the Q1 performance index (lower = faster). Experience is whole
years of service as of 2026-01-01. Operators are grouped into
experience bands, and CORR() measures the overall relationship
across all 88 operators, calculated once in a scalar subquery that
reads the same CTE as the bands.
Finding: no meaningful relationship. Band averages move up and down
with no steady trend (1.036, 1.027, 1.034, 1.023), and the
correlation is -0.09, close to zero. In this data, tenure does not
predict cycle speed, so it would be a poor basis for assignments or
training priorities.
Note: operator skill in the synthetic data is assigned at random,
independent of hire date, which is consistent with this result.
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
                       AND c.dump_location_id = m.dump_location_id
                       AND c.shift_type = m.shift_type
    GROUP BY c.operator_id
),
operator_experience AS (
    SELECT
        os.operator_id,
        os.performance_index,
        EXTRACT(YEAR FROM age(DATE '2026-01-01', op.hire_date)) AS years_experience
    FROM operator_scores os
    INNER JOIN operator op ON os.operator_id = op.operator_id
)

SELECT
    CASE
        WHEN years_experience <= 2  THEN '0-2 years'
        WHEN years_experience <= 7  THEN '3-7 years'
        WHEN years_experience <= 12 THEN '8-12 years'
        ELSE '13+ years'
    END AS experience_group,
    COUNT(*) AS operators,
    ROUND(AVG(performance_index)::numeric, 3) AS avg_index,
    (SELECT ROUND(CORR(performance_index, years_experience)::numeric, 3)
     FROM operator_experience) AS overall_correlation
FROM operator_experience
GROUP BY experience_group
ORDER BY MIN(years_experience);
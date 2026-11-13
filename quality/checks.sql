/*
quality/checks.sql
Data quality checks run before reporting: payload sensor errors,
overloads against haulage policy, and consistency rules between
cycles, equipment, shifts, crews, locations, and downtime.
*/

/*
Q1: Data quality scorecard
Every check returns one row (check name, rows checked, rows failed,
allowed failure %); UNION ALL stacks them, and the final SELECT
calculates percentages and PASS/FAIL once for all checks.
Payload checks follow the 10/10/20 haulage policy: no load may exceed
120% of truck capacity, and no more than 10% of loads may exceed 110%.
The 110% check therefore passes while under its 10% allowance.
Joins are LEFT JOINs and comparisons use IS DISTINCT FROM, so a cycle
with a broken reference is counted as a failure instead of silently
dropping out. Foreign keys prevent that in this schema, but the checks
would still hold on data loaded without them, such as a staging table.
Findings:
- 286 loads (0.19%) are under 10% of capacity: sensor glitches that
  should be excluded or corrected before payload reporting.
- 1,093 loads (0.73%) exceed 110% of capacity, well within the 10%
  allowance; none exceed 120% (the heaviest is about 115%).
- About 11% of loads exceed 100% of capacity. That is normal: trucks
  are loaded around a target, which is why the policy sets a 110%
  threshold with an allowance rather than treating every load above
  capacity as an error.
- All consistency checks pass with zero failures.
Performance: the downtime check runs an EXISTS lookup for each of the
~150,000 cycles. Without an index it scanned every downtime event per
cycle (about 17 seconds); the index on downtime_event (equipment_id,
start_ts) in schema.sql brings it to about 1 second. Writing the overlap
as tstzrange(...) && tstzrange(...) would instead use the index behind
the exclusion constraint, with no new index, at about 3 seconds.
See performance/tuning_notes.md, Exercise 4.
*/

WITH cycle_details AS (
    SELECT
        hc.cycle_id,
        hc.truck_id,
        eqmdtr.payload_capacity_tonnes AS truck_capacity_tonnes,
        eqmdtr.equipment_type AS truck_type,
        hc.shovel_id,
        eqmdsh.equipment_type AS shovel_type,
        hc.operator_id,
        op.employee_number,
        op.crew AS operator_crew,
        sh.crew AS shift_crew,
        hc.shift_id,
        sh.shift_type,
        sh.start_ts,
        sh.end_ts,
        hc.dump_location_id,
        du.location_type AS dump_location_type,
        hc.material_type,
        hc.payload_tonnes,
        hc.arrive_shovel_ts,
        hc.cycle_end_ts
    FROM haul_cycle hc
    LEFT JOIN equipment eqtr ON hc.truck_id = eqtr.equipment_id
    LEFT JOIN equipment_model eqmdtr ON eqtr.model_id = eqmdtr.model_id
    LEFT JOIN equipment eqsh ON hc.shovel_id = eqsh.equipment_id
    LEFT JOIN equipment_model eqmdsh ON eqsh.model_id = eqmdsh.model_id
    LEFT JOIN shift sh ON hc.shift_id = sh.shift_id
    LEFT JOIN location du ON hc.dump_location_id = du.location_id
    LEFT JOIN operator op ON hc.operator_id  = op.operator_id
),
checks AS (
    SELECT
        'Payload under 10% of capacity' AS check_name,
        COUNT(*) AS rows_checked,
        COUNT(*) FILTER (WHERE cd.payload_tonnes < 0.10 * cd.truck_capacity_tonnes) AS rows_failed,
        0 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Payload over 120% of capacity' AS check_name,
        COUNT(*) AS rows_checked,
        COUNT(*) FILTER (WHERE cd.payload_tonnes > 1.20 * cd.truck_capacity_tonnes) AS rows_failed,
        0 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Payload over 110% of capacity' AS check_name,
        COUNT(*) AS rows_checked,
        COUNT(*) FILTER (WHERE cd.payload_tonnes > 1.10 * cd.truck_capacity_tonnes) AS rows_failed,
        10 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Truck ID is not a haul truck' AS check_name,
         COUNT(*) AS rows_checked,
         COUNT(*) FILTER (WHERE cd.truck_type IS DISTINCT FROM 'haul_truck') AS rows_failed,
         0 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Shovel ID is not a shovel' AS check_name,
         COUNT(*) AS rows_checked,
         COUNT(*) FILTER (WHERE cd.shovel_type IS DISTINCT FROM 'shovel') AS rows_failed,
         0 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Cycle outside its shift' AS check_name,
        COUNT(*) AS rows_checked,
        COUNT(*) FILTER (WHERE cd.arrive_shovel_ts < cd.start_ts
                            OR cd.cycle_end_ts > cd.end_ts) AS rows_failed,
        0 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Material sent to wrong destination' AS check_name,
        COUNT(*) AS rows_checked,
        COUNT(*) FILTER (WHERE NOT COALESCE(
                (cd.material_type = 'ore'   AND cd.dump_location_type IN ('crusher', 'stockpile'))
             OR (cd.material_type = 'waste' AND cd.dump_location_type = 'waste_dump'),
                FALSE)) AS rows_failed,
        0 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Operator crew does not match shift crew' AS check_name,
        COUNT(*) AS rows_checked,
        COUNT(*) FILTER (WHERE cd.operator_crew IS DISTINCT FROM cd.shift_crew) AS rows_failed,
        0 AS max_allowed_pct
    FROM cycle_details cd

    UNION ALL

    SELECT
        'Cycle overlaps truck downtime' AS check_name,
        COUNT(*) AS rows_checked,
        COUNT(*) FILTER (WHERE EXISTS (
                SELECT 1 FROM downtime_event d
                WHERE d.equipment_id = cd.truck_id
                  AND d.start_ts < cd.cycle_end_ts
                  AND COALESCE(d.end_ts, 'infinity') > cd.arrive_shovel_ts)) AS rows_failed,
        0 AS max_allowed_pct
    FROM cycle_details cd
)

SELECT
    check_name,
    rows_checked,
    rows_failed,
    ROUND(100.0 * rows_failed / rows_checked, 2) AS pct_failed,
    CASE WHEN 100.0 * rows_failed / rows_checked <= max_allowed_pct
        THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks;

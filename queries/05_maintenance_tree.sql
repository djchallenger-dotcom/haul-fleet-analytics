/*
05_maintenance_tree.sql
The truck component hierarchy, and unplanned failures rolled up from
individual parts to the systems above them, using recursive CTEs.
*/

/*
Q1: What does the truck component hierarchy look like?
component is a self-referencing table (parent_component_id points to
another component). A recursive CTE walks it from the root down: the
anchor selects the root (no parent), and the recursive part repeatedly
joins children to the rows found in the previous round, adding 1 to
depth and appending the child's name to the parent's path, until no
new rows appear. Sorting by path places each component under its
parent. Unlike a fixed chain of self-joins, this handles any depth.
Result: 18 components over 4 levels. Engine is the only system with a
third level (Cooling System, Fuel Injectors, Turbocharger).
*/

WITH RECURSIVE tree AS (
    SELECT
       component_id,
       name,
       0 AS depth,
       name::TEXT AS path
    FROM component
    WHERE parent_component_id IS NULL

    UNION ALL

    SELECT 
       c.component_id,
       c.name,
       t.depth + 1 AS depth,
       t.path || ' > ' || c.name AS path
    FROM component c
    INNER JOIN tree t ON c.parent_component_id = t.component_id
)

SELECT
    tr.depth,
    REPEAT('    ', tr.depth) || tr.name AS component,
    tr.path
FROM tree tr
ORDER BY tr.path;


/*
Q2: Which systems cause the most unplanned downtime once failures are
rolled up the component tree?
Failures are recorded against individual parts. A second recursive CTE
(ancestors) lists every ancestor/descendant pair in the tree, including
each component paired with itself. Joining failures to the descendant
and grouping by the ancestor credits each failure to its own part and
to every system above it. tree (from Q1) supplies names and paths.
All recorded unplanned events are counted, without clipping to the
reporting window (3 events fall partly outside it). COALESCE on end_ts
guards against open events; none are open in this data.
Finding: 754 unplanned failures, ~4,100 hours. Chassis is the largest
system (308 failures, ~1,800 h, 44% of hours), driven by Tires, the
worst single part (182 failures, ~1,040 h). Engine's three parts are
individually mid-table, but rolled up they total 186 failures and
~970 h, nearly matching Tires. A part-level report would miss this.
*/

WITH RECURSIVE tree AS (
    SELECT
       component_id,
       name,
       0 AS depth,
       name::TEXT AS path
    FROM component
    WHERE parent_component_id IS NULL

    UNION ALL

    SELECT 
       c.component_id,
       c.name,
       t.depth + 1 AS depth,
       t.path || ' > ' || c.name AS path
    FROM component c
    INNER JOIN tree t ON c.parent_component_id = t.component_id
),
ancestors AS (
    SELECT 
        component_id AS ancestor_id, 
        component_id AS descendant_id
    FROM component

    UNION ALL

    SELECT 
        a.ancestor_id, 
        c.component_id
    FROM ancestors a
    INNER JOIN component c ON c.parent_component_id = a.descendant_id
),
failures AS (
    SELECT
        dte.component_id,
        EXTRACT(EPOCH FROM SUM(
            COALESCE(dte.end_ts, (SELECT MAX(end_ts) FROM shift)) - dte.start_ts
            )) / 3600 AS total_downtime_hours,
        COUNT(*) AS failure_count
    FROM downtime_event dte
    INNER JOIN equipment eq ON dte.equipment_id = eq.equipment_id
    INNER JOIN equipment_model eqm ON eq.model_id = eqm.model_id
    WHERE dte.category = 'unplanned_maintenance'
      AND eqm.equipment_type = 'haul_truck'
    GROUP BY dte.component_id 
)

SELECT
    tr.depth,
    REPEAT('    ', tr.depth) || tr.name AS component,
    COALESCE(SUM(fa.failure_count), 0) AS failures,
    ROUND(COALESCE(SUM(fa.total_downtime_hours), 0), 0) AS downtime_hours,
    tr.path
FROM tree tr
INNER JOIN ancestors an ON an.ancestor_id = tr.component_id
LEFT JOIN failures fa ON fa.component_id = an.descendant_id
GROUP BY tr.component_id, tr.depth, tr.name, tr.path
ORDER BY tr.path;

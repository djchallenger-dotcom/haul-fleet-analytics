/*
queries/mssql/05_maintenance_tree.sql
T-SQL ports of queries/05_maintenance_tree.sql: Q1 (component
hierarchy) and Q2 (failure roll-up). Comments focus on what differs
from the PostgreSQL version; see the original for the full analysis
and findings. Dialect differences are summarized in dialects.md.
*/

/*
Q1: Component hierarchy (T-SQL port)
Changes from PostgreSQL:
- WITH instead of WITH RECURSIVE; SQL Server detects recursion
  automatically and rejects the RECURSIVE keyword.
- Column types must match exactly between the anchor and the recursive
  part. path is cast to nvarchar(1000) in both; PostgreSQL only needed
  the anchor cast to text.
- String functions: + for concatenation, REPLICATE instead of REPEAT.
- SQL Server stops recursion after 100 levels by default (raise with
  OPTION (MAXRECURSION n)); this tree has 4.
Results match the PostgreSQL version.
*/

WITH tree AS (
    SELECT
       component_id,
       name,
       0 AS depth,
       CAST(name AS nvarchar(1000)) AS path
    FROM component
    WHERE parent_component_id IS NULL

    UNION ALL

    SELECT 
       c.component_id,
       c.name,
       t.depth + 1 AS depth,
       CAST(t.path + ' > ' + c.name AS nvarchar(1000)) AS path
    FROM component c
    INNER JOIN tree t ON c.parent_component_id = t.component_id
)

SELECT
    tr.depth,
    REPLICATE('    ', tr.depth) + tr.name AS component,
    tr.path
FROM tree tr
ORDER BY tr.path;



/*
Q2: Failure roll-up through the component tree (T-SQL port)
Both recursive CTEs (tree from Q1, and ancestors) port with only the
RECURSIVE keyword removed; ancestors has integer columns only, so its
types already match between anchor and recursive part.
Changes from PostgreSQL:
- SQL Server does not allow a subquery inside an aggregate, so the
  fallback end time for open events moves into a period CTE that is
  cross-joined, instead of (SELECT MAX(end_ts) FROM shift) inside SUM.
- Durations use DATEDIFF(second, start, end) / 3600.0 instead of
  EXTRACT(EPOCH FROM ...); see 01_fleet_kpis.sql Q3 for why seconds.
- REPLICATE and + replace REPEAT and ||.
Results match the PostgreSQL version.
*/

WITH tree AS (
    SELECT
       component_id,
       name,
       0 AS depth,
       CAST(name AS nvarchar(1000)) AS path
    FROM component
    WHERE parent_component_id IS NULL

    UNION ALL

    SELECT 
       c.component_id,
       c.name,
       t.depth + 1 AS depth,
       CAST(t.path + ' > ' + c.name AS nvarchar(1000)) AS path
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
period AS (
    SELECT MAX(end_ts) AS period_end
    FROM shift
),
failures AS (
    SELECT
        dte.component_id,
        SUM(DATEDIFF(second, dte.start_ts,
                     COALESCE(dte.end_ts, p.period_end))) / 3600.0 AS total_downtime_hours,
        COUNT(*) AS failure_count
    FROM downtime_event dte
    INNER JOIN equipment eq ON dte.equipment_id = eq.equipment_id
    INNER JOIN equipment_model eqm ON eq.model_id = eqm.model_id
    CROSS JOIN period p
    WHERE dte.category = 'unplanned_maintenance'
      AND eqm.equipment_type = 'haul_truck'
    GROUP BY dte.component_id
)

SELECT
    tr.depth,
    REPLICATE('    ', tr.depth) + tr.name AS component,
    COALESCE(SUM(fa.failure_count), 0) AS failures,
    ROUND(COALESCE(SUM(fa.total_downtime_hours), 0), 0) AS downtime_hours,
    tr.path
FROM tree tr
INNER JOIN ancestors an ON an.ancestor_id = tr.component_id
LEFT JOIN failures fa ON fa.component_id = an.descendant_id
GROUP BY tr.component_id, tr.depth, tr.name, tr.path
ORDER BY tr.path;
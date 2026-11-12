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

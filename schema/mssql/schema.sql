-- =============================================================================
-- Haul Fleet Analytics: MSSQL schema
-- Models an open-pit mine haul fleet: equipment, operators, shifts,
-- haul cycles, downtime, and fuel. All data in this project is synthetic.
-- =============================================================================

-- Differences from the PostgreSQL schema are documented in dialects.md.
-- SQL Server has no exclusion constraints; overlap rules for operator
-- assignments and downtime are handled separately (see below).

-- Drop in reverse dependency order: tables that reference others first.
DROP TABLE IF EXISTS fuel_event;           -- references equipment, location
DROP TABLE IF EXISTS downtime_event;       -- references equipment, component
DROP TABLE IF EXISTS haul_cycle;           -- references equipment, operator, shift, location

-- The partition scheme and function can only be dropped once no table uses them
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'ps_haul_cycle_month')
    DROP PARTITION SCHEME ps_haul_cycle_month;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pf_haul_cycle_month')
    DROP PARTITION FUNCTION pf_haul_cycle_month;

DROP TABLE IF EXISTS operator_assignment;  -- references shift, operator, equipment
DROP TABLE IF EXISTS shift;
DROP TABLE IF EXISTS component;            -- references only itself
DROP TABLE IF EXISTS operator;
DROP TABLE IF EXISTS location;
DROP TABLE IF EXISTS equipment;            -- references equipment_model
DROP TABLE IF EXISTS equipment_model;

-- -----------------------------------------------------------------------------
-- Reference tables
-- -----------------------------------------------------------------------------

CREATE TABLE equipment_model (
    model_id           int IDENTITY(1,1) PRIMARY KEY,
    manufacturer       nvarchar(50) NOT NULL,
    model_name         nvarchar(50) NOT NULL,
    equipment_type     nvarchar(20) NOT NULL
        CHECK (equipment_type IN ('haul_truck', 'shovel', 'loader')),
    payload_capacity_tonnes  decimal(6,1) CHECK (payload_capacity_tonnes > 0),
    fuel_capacity_litres     decimal(7,1) CHECK (fuel_capacity_litres > 0),
    UNIQUE (manufacturer, model_name)
);

CREATE TABLE equipment (
    equipment_id      int IDENTITY(1,1) PRIMARY KEY,
    unit_number       nvarchar(20) NOT NULL UNIQUE,          -- e.g. 'HT-104'
    model_id          int NOT NULL REFERENCES equipment_model (model_id),
    commissioned_date date    NOT NULL,
    retired_date      date,
    CHECK (retired_date IS NULL OR retired_date > commissioned_date)
);

CREATE TABLE operator (
    operator_id      int IDENTITY(1,1) PRIMARY KEY,
    employee_number  nvarchar(20) NOT NULL UNIQUE,
    first_name       nvarchar(50) NOT NULL,
    last_name        nvarchar(50) NOT NULL,
    crew             char(1) NOT NULL CHECK (crew IN ('A', 'B', 'C', 'D')),
    hire_date        date    NOT NULL
);

CREATE TABLE location (
    location_id    int IDENTITY(1,1) PRIMARY KEY,
    name           nvarchar(100) NOT NULL UNIQUE,
    location_type  nvarchar(20) NOT NULL
        CHECK (location_type IN ('shovel_face', 'crusher', 'stockpile',
                                 'waste_dump', 'fuel_bay', 'shop'))
);

-- Self-referencing hierarchy (truck > powertrain > engine > turbocharger).
-- Used later for recursive CTE queries.
CREATE TABLE component (
    component_id         int IDENTITY(1,1) PRIMARY KEY,
    parent_component_id  int REFERENCES component (component_id),
    name                 nvarchar(100) NOT NULL,
    UNIQUE (parent_component_id, name)
);

-- -----------------------------------------------------------------------------
-- Shifts and assignments
-- -----------------------------------------------------------------------------

CREATE TABLE shift (
    shift_id    int IDENTITY(1,1) PRIMARY KEY,
    shift_date  date            NOT NULL,
    shift_type  nvarchar(10)    NOT NULL CHECK (shift_type IN ('day', 'night')),
    crew        char(1)         NOT NULL CHECK (crew IN ('A', 'B', 'C', 'D')),
    start_ts    datetimeoffset  NOT NULL,
    end_ts      datetimeoffset  NOT NULL,
    UNIQUE (shift_date, shift_type),
    CHECK (end_ts > start_ts)
);

-- Which operator ran which unit in each shift. PostgreSQL enforced "no
-- overlapping assignments" with exclusion constraints, which SQL Server
-- lacks. Assignments here always cover one whole shift, so uniqueness
-- per shift enforces the same rule: one operator per truck per shift,
-- and one truck per operator per shift. This would not catch overlaps
-- between partial-shift assignments; see dialects.md.
CREATE TABLE operator_assignment (
    assignment_id  int IDENTITY(1,1) PRIMARY KEY,
    shift_id       int            NOT NULL REFERENCES shift (shift_id),
    operator_id    int            NOT NULL REFERENCES operator (operator_id),
    equipment_id   int            NOT NULL REFERENCES equipment (equipment_id),
    start_ts       datetimeoffset NOT NULL,
    end_ts         datetimeoffset NOT NULL,
    CHECK (end_ts > start_ts),
    UNIQUE (shift_id, equipment_id),
    UNIQUE (shift_id, operator_id)
);

-- -----------------------------------------------------------------------------
-- Haul cycles (the fact table): partitioned by month on load_start_ts
-- -----------------------------------------------------------------------------

-- Monthly partitions on load_start_ts. Boundaries are midnight mine-local
-- time (-07:00, Arizona has no DST), so each partition matches a reporting
-- month. RANGE RIGHT puts each boundary value in the partition to its
-- right: [Jan 1, Feb 1), [Feb 1, Mar 1), and so on. Seven boundaries make
-- eight partitions; the first (before Jan 1) and last (from Jul 1) catch
-- anything outside the reporting period, like PostgreSQL's DEFAULT
-- partition.

CREATE PARTITION FUNCTION pf_haul_cycle_month (datetimeoffset)
AS RANGE RIGHT FOR VALUES (
    '2026-01-01T00:00:00-07:00', '2026-02-01T00:00:00-07:00',
    '2026-03-01T00:00:00-07:00', '2026-04-01T00:00:00-07:00',
    '2026-05-01T00:00:00-07:00', '2026-06-01T00:00:00-07:00',
    '2026-07-01T00:00:00-07:00');

CREATE PARTITION SCHEME ps_haul_cycle_month
AS PARTITION pf_haul_cycle_month ALL TO ([PRIMARY]);

CREATE TABLE haul_cycle (
    cycle_id          bigint          IDENTITY(1,1) NOT NULL,
    truck_id          int             NOT NULL REFERENCES equipment(equipment_id),
    shovel_id         int             NOT NULL REFERENCES equipment(equipment_id),
    operator_id       int             NOT NULL REFERENCES operator(operator_id),
    shift_id          int             NOT NULL REFERENCES shift(shift_id),
    load_location_id  int             NOT NULL REFERENCES location(location_id),
    dump_location_id  int             NOT NULL REFERENCES location(location_id),
    material_type     nvarchar(10)    NOT NULL CHECK (material_type IN ('ore', 'waste')),
    payload_tonnes    decimal(6,1)    NOT NULL CHECK (payload_tonnes > 0),
    arrive_shovel_ts  datetimeoffset  NOT NULL,   -- queue starts
    load_start_ts     datetimeoffset  NOT NULL,
    load_end_ts       datetimeoffset  NOT NULL,   -- loaded haul starts
    dump_start_ts     datetimeoffset  NOT NULL,
    dump_end_ts       datetimeoffset  NOT NULL,   -- empty return starts
    cycle_end_ts      datetimeoffset  NOT NULL,   -- back at shovel
    CHECK (truck_id <> shovel_id),
    CHECK (arrive_shovel_ts <= load_start_ts
        AND load_start_ts    <  load_end_ts
        AND load_end_ts      <= dump_start_ts
        AND dump_start_ts    <  dump_end_ts
        AND dump_end_ts      <= cycle_end_ts),
    -- On a partitioned table the primary key must include the partition key.
    PRIMARY KEY (cycle_id, load_start_ts)
) ON ps_haul_cycle_month (load_start_ts);

-- -----------------------------------------------------------------------------
-- Downtime event and fuel event
-- -----------------------------------------------------------------------------

CREATE TABLE downtime_event (
    downtime_id   int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    equipment_id  int             NOT NULL REFERENCES equipment(equipment_id),
    component_id  int             REFERENCES component(component_id),
    category      nvarchar(25)    NOT NULL
        CHECK (category IN ('planned_maintenance', 'unplanned_maintenance',
                            'operational_delay', 'standby')),
    start_ts      datetimeoffset  NOT NULL,
    end_ts        datetimeoffset,              -- NULL = still down
    notes         nvarchar(200),
    CHECK (end_ts IS NULL OR end_ts > start_ts)
);
GO

-- PostgreSQL blocked overlapping downtime per unit with an exclusion
-- constraint. SQL Server has no equivalent, and downtime events have
-- arbitrary start and end times, so this trigger enforces the rule.
-- It checks every inserted or updated row at once (set-based), so bulk
-- loads run it once per statement, not once per row.
-- An open event (end_ts NULL) is treated as running indefinitely.

CREATE TRIGGER trg_downtime_event_no_overlap
ON downtime_event
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN downtime_event d
          ON  d.equipment_id = i.equipment_id
          AND d.downtime_id <> i.downtime_id
          AND d.start_ts < COALESCE(i.end_ts, '9999-12-31')
          AND COALESCE(d.end_ts, '9999-12-31') > i.start_ts
    )
        THROW 50001, 'Overlapping downtime events for the same equipment.', 1;
END;
GO

CREATE INDEX ix_downtime_event_equipment_id_start_ts
    ON downtime_event (equipment_id, start_ts);

CREATE TABLE fuel_event (
    fuel_event_id  int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    equipment_id   int      NOT NULL REFERENCES equipment(equipment_id),
    location_id    int      NOT NULL REFERENCES location(location_id),
    fuel_ts        datetimeoffset  NOT NULL,
    litres         decimal(7,1) NOT NULL CHECK (litres > 0)
);

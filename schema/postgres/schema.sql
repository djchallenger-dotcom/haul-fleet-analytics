-- =============================================================================
-- Haul Fleet Analytics: PostgreSQL schema
-- Models an open-pit mine haul fleet: equipment, operators, shifts,
-- haul cycles, downtime, and fuel. All data in this project is synthetic.
-- =============================================================================

-- btree_gist lets exclusion constraints combine "=" on IDs with "&&" on time
-- ranges, which is how we block overlapping assignments and downtime events.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- -----------------------------------------------------------------------------
-- Reference tables
-- -----------------------------------------------------------------------------

CREATE TABLE equipment_model (
    model_id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    manufacturer             text    NOT NULL,
    model_name               text    NOT NULL,
    equipment_type           text    NOT NULL
        CHECK (equipment_type IN ('haul_truck', 'shovel', 'loader')),
    payload_capacity_tonnes  numeric(6,1) CHECK (payload_capacity_tonnes > 0),
    fuel_capacity_litres     numeric(7,1) CHECK (fuel_capacity_litres > 0),
    UNIQUE (manufacturer, model_name)
);

CREATE TABLE equipment (
    equipment_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    unit_number       text    NOT NULL UNIQUE,          -- e.g. 'HT-104'
    model_id          integer NOT NULL REFERENCES equipment_model,
    commissioned_date date    NOT NULL,
    retired_date      date,
    CHECK (retired_date IS NULL OR retired_date > commissioned_date)
);

CREATE TABLE operator (
    operator_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_number  text    NOT NULL UNIQUE,
    first_name       text    NOT NULL,
    last_name        text    NOT NULL,
    crew             char(1) NOT NULL CHECK (crew IN ('A', 'B', 'C', 'D')),
    hire_date        date    NOT NULL
);

CREATE TABLE location (
    location_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           text NOT NULL UNIQUE,
    location_type  text NOT NULL
        CHECK (location_type IN ('shovel_face', 'crusher', 'stockpile',
                                 'waste_dump', 'fuel_bay', 'shop'))
);

-- Self-referencing hierarchy (truck > powertrain > engine > turbocharger).
-- Used later for recursive CTE queries.
CREATE TABLE component (
    component_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_component_id  integer REFERENCES component,
    name                 text NOT NULL,
    UNIQUE NULLS NOT DISTINCT (parent_component_id, name)
);

-- -----------------------------------------------------------------------------
-- Shifts and assignments
-- -----------------------------------------------------------------------------

CREATE TABLE shift (
    shift_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shift_date  date        NOT NULL,
    shift_type  text        NOT NULL CHECK (shift_type IN ('day', 'night')),
    crew        char(1)     NOT NULL CHECK (crew IN ('A', 'B', 'C', 'D')),
    start_ts    timestamptz NOT NULL,
    end_ts      timestamptz NOT NULL,
    UNIQUE (shift_date, shift_type),
    CHECK (end_ts > start_ts)
);

-- Which operator ran which unit, and when. The two exclusion constraints
-- guarantee no truck has two operators at once and no operator is in two
-- trucks at once.
CREATE TABLE operator_assignment (
    assignment_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shift_id       integer     NOT NULL REFERENCES shift,
    operator_id    integer     NOT NULL REFERENCES operator,
    equipment_id   integer     NOT NULL REFERENCES equipment,
    start_ts       timestamptz NOT NULL,
    end_ts         timestamptz NOT NULL,
    CHECK (end_ts > start_ts),
    EXCLUDE USING gist (equipment_id WITH =, tstzrange(start_ts, end_ts) WITH &&),
    EXCLUDE USING gist (operator_id  WITH =, tstzrange(start_ts, end_ts) WITH &&)
);

-- -----------------------------------------------------------------------------
-- Haul cycles (the fact table): partitioned by month on load_start_ts
-- -----------------------------------------------------------------------------

CREATE TABLE haul_cycle (
    cycle_id          bigint GENERATED ALWAYS AS IDENTITY,
    truck_id          integer      NOT NULL REFERENCES equipment,
    shovel_id         integer      NOT NULL REFERENCES equipment,
    operator_id       integer      NOT NULL REFERENCES operator,
    shift_id          integer      NOT NULL REFERENCES shift,
    load_location_id  integer      NOT NULL REFERENCES location,
    dump_location_id  integer      NOT NULL REFERENCES location,
    material_type     text         NOT NULL CHECK (material_type IN ('ore', 'waste')),
    payload_tonnes    numeric(6,1) NOT NULL CHECK (payload_tonnes > 0),
    arrive_shovel_ts  timestamptz  NOT NULL,   -- queue starts
    load_start_ts     timestamptz  NOT NULL,
    load_end_ts       timestamptz  NOT NULL,   -- loaded haul starts
    dump_start_ts     timestamptz  NOT NULL,
    dump_end_ts       timestamptz  NOT NULL,   -- empty return starts
    cycle_end_ts      timestamptz  NOT NULL,   -- back at shovel
    CHECK (truck_id <> shovel_id),
    CHECK (arrive_shovel_ts <= load_start_ts
       AND load_start_ts    <  load_end_ts
       AND load_end_ts      <= dump_start_ts
       AND dump_start_ts    <  dump_end_ts
       AND dump_end_ts      <= cycle_end_ts),
    -- On a partitioned table the primary key must include the partition key.
    PRIMARY KEY (cycle_id, load_start_ts)
) PARTITION BY RANGE (load_start_ts);

-- Monthly partitions for Jan-Jun 2026, plus a default for anything outside.
-- Boundaries are midnight mine-local time (America/Phoenix), so each
-- partition matches a reporting month. Plain dates would be interpreted in
-- the session time zone (UTC in the container), putting every boundary at
-- 5 PM local and splitting the last evening of each month into the next
-- partition.
DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series(date '2026-01-01', date '2026-06-01', interval '1 month')::date
    LOOP
        EXECUTE format(
            'CREATE TABLE haul_cycle_%s PARTITION OF haul_cycle
                 FOR VALUES FROM (%L) TO (%L)',
            to_char(m, 'YYYY_MM'),
            m::timestamp AT TIME ZONE 'America/Phoenix',
            (m + interval '1 month')::timestamp AT TIME ZONE 'America/Phoenix');
    END LOOP;
END $$;

CREATE TABLE haul_cycle_default PARTITION OF haul_cycle DEFAULT;

-- -----------------------------------------------------------------------------
-- Downtime and fuel
-- -----------------------------------------------------------------------------

CREATE TABLE downtime_event (
    downtime_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_id  integer     NOT NULL REFERENCES equipment,
    component_id  integer     REFERENCES component,
    category      text        NOT NULL
        CHECK (category IN ('planned_maintenance', 'unplanned_maintenance',
                            'operational_delay', 'standby')),
    start_ts      timestamptz NOT NULL,
    end_ts        timestamptz,              -- NULL = still down
    notes         text,
    CHECK (end_ts IS NULL OR end_ts > start_ts),
    -- A unit can't be in two downtime events at once.
    EXCLUDE USING gist (equipment_id WITH =, tstzrange(start_ts, end_ts) WITH &&)
);

CREATE TABLE fuel_event (
    fuel_event_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_id   integer      NOT NULL REFERENCES equipment,
    location_id    integer      NOT NULL REFERENCES location,
    fuel_ts        timestamptz  NOT NULL,
    litres         numeric(7,1) NOT NULL CHECK (litres > 0)
);

-- -----------------------------------------------------------------------------
-- Indexes (beyond those created by PKs, UNIQUE, and exclusion constraints).
-- Kept deliberately minimal: the performance/ folder will show measured
-- before/after results for any indexes added later.
-- -----------------------------------------------------------------------------

CREATE INDEX ON haul_cycle (truck_id, load_start_ts);
CREATE INDEX ON haul_cycle (shift_id);
CREATE INDEX ON fuel_event (equipment_id, fuel_ts);

-- Supports per-truck downtime lookups by time: availability (01 Q3),
-- idle-stretch causes (04 Q2), and the downtime overlap check in
-- quality/checks.sql.
CREATE INDEX ON downtime_event (equipment_id, start_ts);

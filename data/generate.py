"""
Synthetic data generator for haul-fleet-analytics.

Fills the PostgreSQL database with six months of fake but realistic
open-pit haul fleet data. The random seed is fixed, so every run produces
exactly the same data. Re-running the script wipes and reloads all tables.

Usage (from the repo root):
    1. Start the database:  docker compose up -d
    2. Install the driver:  pip install -r requirements.txt
    3. Run this script:     python data/generate.py
"""

import random
from datetime import date, datetime, timedelta, timezone

import psycopg

# =============================================================================
# SETTINGS
# =============================================================================
SETTINGS = {
    "db": "host=localhost port=5432 dbname=haul_fleet user=fleet password=fleet",
    "seed": 42,
    "start_date": date(2026, 1, 1),
    "end_date": date(2026, 6, 30),        # inclusive
    "operators_per_crew": 22,
    "night_shift_slowdown": 1.10,         # night cycles run ~10% slower
    "overload_rate": 0.01,                # share of loads over truck capacity
    "payload_glitch_rate": 0.002,         # share of bogus near-zero payloads
}

MINE_TZ = timezone(timedelta(hours=-7))   # Arizona: MST all year, no DST
rng = random.Random(SETTINGS["seed"])

# =============================================================================
# REFERENCE DATA
# IDs are assigned by Postgres in insert order, so list position = ID.
# =============================================================================

# (manufacturer, model, type, payload tonnes, fuel litres, burn litres/hour)
EQUIPMENT_MODELS = [
    ("Caterpillar", "793F",    "haul_truck", 227, 4542, 160),   # model 1
    ("Komatsu",     "930E",    "haul_truck", 290, 4542, 190),   # model 2
    ("P&H",         "4100XPC", "shovel",     None, None, None), # model 3
    ("Caterpillar", "994K",    "loader",     None, 4500, None), # model 4
]

# (unit number prefix, model id, how many)
FLEET = [
    ("HT-1", 1, 12),   # HT-101 .. HT-112
    ("HT-2", 2, 8),    # HT-201 .. HT-208
    ("SH-0", 3, 3),    # SH-01 .. SH-03
    ("LD-0", 4, 1),    # LD-01
]

LOCATIONS = [
    ("North Pit Face 1", "shovel_face"),  # 1  worked by shovel SH-01
    ("North Pit Face 2", "shovel_face"),  # 2  worked by shovel SH-02
    ("South Pit Face",   "shovel_face"),  # 3  worked by shovel SH-03
    ("Primary Crusher",  "crusher"),      # 4
    ("ROM Stockpile",    "stockpile"),    # 5
    ("East Waste Dump",  "waste_dump"),   # 6
    ("West Waste Dump",  "waste_dump"),   # 7
    ("Fuel Bay",         "fuel_bay"),     # 8
    ("Truck Shop",       "shop"),         # 9
]
FUEL_BAY_ID = 8

# For each shovel face: material dug, and destinations as
# (dump location id, share of loads, typical loaded haul minutes)
SHOVEL_PLAN = {
    1: ("ore",   [(4, 0.8, 14.0), (5, 0.2, 10.0)]),
    2: ("waste", [(6, 0.5, 9.0),  (7, 0.5, 12.0)]),
    3: ("waste", [(6, 0.3, 13.0), (7, 0.7, 8.0)]),
}

# (component name, parent name). Parents must come before children.
COMPONENTS = [
    ("Haul Truck",        None),
    ("Powertrain",        "Haul Truck"),
    ("Engine",            "Powertrain"),
    ("Turbocharger",      "Engine"),
    ("Fuel Injectors",    "Engine"),
    ("Cooling System",    "Engine"),
    ("Drive System",      "Powertrain"),
    ("Final Drive",       "Powertrain"),
    ("Chassis",           "Haul Truck"),
    ("Suspension Struts", "Chassis"),
    ("Tires",             "Chassis"),
    ("Brakes",            "Chassis"),
    ("Hydraulics",        "Haul Truck"),
    ("Hoist Cylinders",   "Hydraulics"),
    ("Steering",          "Hydraulics"),
    ("Electrical",        "Haul Truck"),
    ("Alternator",        "Electrical"),
    ("Payload Monitor",   "Electrical"),
]

# Which components fail, and how often relative to each other
FAILURE_WEIGHTS = {
    "Tires": 25, "Hoist Cylinders": 12, "Suspension Struts": 10,
    "Cooling System": 10, "Fuel Injectors": 8, "Turbocharger": 6,
    "Brakes": 8, "Steering": 6, "Alternator": 5, "Payload Monitor": 5,
    "Drive System": 3, "Final Drive": 2,
}

FIRST_NAMES = [
    "Miguel", "Sarah", "James", "Ana", "Robert", "Maria", "David", "Linda",
    "Jose", "Karen", "Daniel", "Rosa", "Tom", "Angela", "Luis", "Jessica",
    "Kevin", "Elena", "Brian", "Teresa", "Carlos", "Amy", "Ray", "Gloria",
]
LAST_NAMES = [
    "Garcia", "Smith", "Martinez", "Johnson", "Lopez", "Brown", "Hernandez",
    "Davis", "Gonzalez", "Wilson", "Ramirez", "Anderson", "Flores", "Taylor",
    "Rivera", "Thomas", "Torres", "Moore", "Ortiz", "Jackson", "Morales",
    "White", "Chavez", "Harris", "Ruiz", "Clark", "Valenzuela", "Lewis",
]


# =============================================================================
# BUILDERS: each returns plain Python rows ready to load
# =============================================================================

def build_equipment():
    """Returns equipment rows plus a list of truck dicts used later."""
    rows, trucks, shovel_ids = [], [], []
    equipment_id = 0
    for prefix, model_id, count in FLEET:
        for n in range(1, count + 1):
            equipment_id += 1
            unit = f"{prefix}{n:02d}"
            commissioned = date(rng.randint(2015, 2024), rng.randint(1, 12), 1)
            rows.append((unit, model_id, commissioned))
            model = EQUIPMENT_MODELS[model_id - 1]
            if model[2] == "haul_truck":
                trucks.append({"id": equipment_id, "unit": unit,
                               "capacity": model[3], "burn_rate": model[5]})
            elif model[2] == "shovel":
                shovel_ids.append(equipment_id)
    return rows, trucks, shovel_ids


def build_operators():
    """Returns operator rows, operator IDs grouped by crew, and skill factors."""
    rows, by_crew, skill = [], {}, {}
    operator_id = 0
    for crew in "ABCD":
        by_crew[crew] = []
        for _ in range(SETTINGS["operators_per_crew"]):
            operator_id += 1
            rows.append((
                f"E{1000 + operator_id}",
                rng.choice(FIRST_NAMES),
                rng.choice(LAST_NAMES),
                crew,
                date(rng.randint(2008, 2025), rng.randint(1, 12), rng.randint(1, 28)),
            ))
            by_crew[crew].append(operator_id)
            # Below 1.0 = faster than average, above 1.0 = slower
            skill[operator_id] = rng.uniform(0.92, 1.10)
    return rows, by_crew, skill


def build_shifts():
    """12-hour day/night shifts. Crews work 4-day blocks: A/B, then C/D."""
    rows = []
    day = SETTINGS["start_date"]
    while day <= SETTINGS["end_date"]:
        block = ((day - SETTINGS["start_date"]).days // 4) % 2
        day_crew, night_crew = ("A", "B") if block == 0 else ("C", "D")
        six_am = datetime(day.year, day.month, day.day, 6, tzinfo=MINE_TZ)
        rows.append((day, "day", day_crew, six_am, six_am + timedelta(hours=12)))
        rows.append((day, "night", night_crew,
                     six_am + timedelta(hours=12), six_am + timedelta(hours=24)))
        day += timedelta(days=1)
    return rows


def build_downtime(trucks, component_ids, period_start, period_end):
    """Non-overlapping downtime events per truck. An event still running at
    the end of the period is left open (end_ts NULL)."""
    rows = []
    windows = {}   # truck id -> list of (start, end) used when building cycles
    leaf_names = list(FAILURE_WEIGHTS)
    leaf_weights = list(FAILURE_WEIGHTS.values())

    for truck in trucks:
        windows[truck["id"]] = []
        cursor = period_start
        while True:
            cursor += timedelta(hours=rng.expovariate(1 / 30))  # avg 30 h apart
            if cursor >= period_end:
                break
            category = rng.choices(
                ["planned_maintenance", "unplanned_maintenance",
                 "operational_delay", "standby"],
                weights=[15, 30, 45, 10])[0]
            component_id, notes = None, None
            if category == "planned_maintenance":
                hours = rng.uniform(8, 14)
                notes = "Scheduled PM service"
            elif category == "unplanned_maintenance":
                hours = min(max(rng.lognormvariate(1.3, 0.9), 0.5), 72)
                component = rng.choices(leaf_names, weights=leaf_weights)[0]
                component_id = component_ids[component]
                notes = f"{component} failure"
            elif category == "operational_delay":
                hours = rng.uniform(0.25, 1.5)
                notes = rng.choice(["Blasting clearance", "Road watering",
                                    "Shovel move", "Dump closed"])
            else:
                hours = rng.uniform(1, 6)
                notes = "No operator available"

            end = cursor + timedelta(hours=hours)
            open_event = end > period_end
            rows.append((truck["id"], component_id, category, cursor,
                         None if open_event else end, notes))
            windows[truck["id"]].append((cursor, end))
            cursor = end
    return rows, windows


def build_cycles_assignments_fuel(shifts, trucks, shovel_ids, operators_by_crew,
                                  skill, downtime_windows):
    """Simulates each truck through each shift, cycle by cycle."""
    cycle_rows, assignment_rows, fuel_rows = [], [], []

    for shift_index, (shift_date, shift_type, crew, start, end) in enumerate(shifts):
        shift_id = shift_index + 1
        crew_ops = operators_by_crew[crew][:]
        rng.shuffle(crew_ops)
        slow_shift = SETTINGS["night_shift_slowdown"] if shift_type == "night" else 1.0

        for truck_index, truck in enumerate(trucks):
            operator_id = crew_ops[truck_index]
            face = (truck_index + shift_index) % 3 + 1   # rotate trucks across shovels
            shovel_id = shovel_ids[face - 1]
            material, destinations = SHOVEL_PLAN[face]
            slow = slow_shift * skill[operator_id]

            # Downtime windows touching this shift
            downs = [(s, e) for s, e in downtime_windows[truck["id"]]
                     if s < end and e > start]

            t = start + timedelta(minutes=20)        # shift change / hot seat
            stop = end - timedelta(minutes=15)
            operating = timedelta()
            cycles_this_shift = 0

            while t < stop:
                current = next((e for s, e in downs if s <= t < e), None)
                if current:                           # truck is down: skip ahead
                    t = current
                    continue
                next_down = min((s for s, e in downs if s > t), default=None)

                dest_id, _, haul_min = rng.choices(
                    destinations, weights=[d[1] for d in destinations])[0]
                queue = timedelta(minutes=rng.expovariate(1 / 3.0) * slow)
                load = timedelta(minutes=rng.uniform(2.5, 4.0))
                haul = timedelta(minutes=haul_min * rng.uniform(0.9, 1.15) * slow)
                dump = timedelta(minutes=rng.uniform(0.8, 1.5))
                ret = timedelta(minutes=haul_min * 0.75 * rng.uniform(0.9, 1.15) * slow)

                arrive = t
                load_start = arrive + queue
                load_end = load_start + load
                dump_start = load_end + haul
                dump_end = dump_start + dump
                cycle_end = dump_end + ret

                if next_down and cycle_end > next_down:
                    t = next_down                     # breakdown before finishing
                    continue
                if cycle_end > stop:
                    break

                payload = truck["capacity"] * rng.gauss(0.95, 0.04)
                roll = rng.random()
                if roll < SETTINGS["overload_rate"]:
                    payload = truck["capacity"] * rng.uniform(1.08, 1.15)
                elif roll < SETTINGS["overload_rate"] + SETTINGS["payload_glitch_rate"]:
                    payload = rng.uniform(0.5, 5.0)   # payload monitor glitch

                cycle_rows.append((
                    truck["id"], shovel_id, operator_id, shift_id, face, dest_id,
                    material, round(payload, 1), arrive, load_start, load_end,
                    dump_start, dump_end, cycle_end,
                ))
                operating += cycle_end - arrive
                cycles_this_shift += 1
                t = cycle_end

            if cycles_this_shift:
                assignment_rows.append((shift_id, operator_id, truck["id"], start, end))
                hours = operating.total_seconds() / 3600
                litres = min(hours * truck["burn_rate"] * rng.uniform(0.9, 1.1), 4542)
                fuel_time = stop + timedelta(minutes=rng.uniform(2, 12))
                fuel_rows.append((truck["id"], FUEL_BAY_ID, fuel_time, round(litres, 1)))

    return cycle_rows, assignment_rows, fuel_rows


# =============================================================================
# LOADING
# =============================================================================

def copy_rows(cur, table, columns, rows):
    """Bulk-load rows with COPY, which is much faster than INSERTs."""
    with cur.copy(f"COPY {table} ({', '.join(columns)}) FROM STDIN") as copy:
        for row in rows:
            copy.write_row(row)
    print(f"  {table:<20} {len(rows):>8,} rows")


def main():
    period_start = datetime.combine(SETTINGS["start_date"], datetime.min.time(), MINE_TZ)
    period_end = datetime.combine(SETTINGS["end_date"] + timedelta(days=2),
                                  datetime.min.time(), MINE_TZ)

    print("Generating data...")
    equipment_rows, trucks, shovel_ids = build_equipment()
    operator_rows, operators_by_crew, skill = build_operators()
    shift_rows = build_shifts()
    component_ids = {name: i + 1 for i, (name, _) in enumerate(COMPONENTS)}
    component_rows = [(component_ids[parent] if parent else None, name)
                      for name, parent in COMPONENTS]
    downtime_rows, downtime_windows = build_downtime(
        trucks, component_ids, period_start, period_end)
    cycle_rows, assignment_rows, fuel_rows = build_cycles_assignments_fuel(
        shift_rows, trucks, shovel_ids, operators_by_crew, skill, downtime_windows)

    print("Loading into PostgreSQL...")
    with psycopg.connect(SETTINGS["db"]) as conn, conn.cursor() as cur:
        cur.execute("""
            TRUNCATE equipment_model, equipment, operator, location, component,
                     shift, operator_assignment, haul_cycle, downtime_event,
                     fuel_event
            RESTART IDENTITY CASCADE
        """)
        copy_rows(cur, "equipment_model",
                  ["manufacturer", "model_name", "equipment_type",
                   "payload_capacity_tonnes", "fuel_capacity_litres"],
                  [m[:5] for m in EQUIPMENT_MODELS])
        copy_rows(cur, "equipment",
                  ["unit_number", "model_id", "commissioned_date"], equipment_rows)
        copy_rows(cur, "operator",
                  ["employee_number", "first_name", "last_name", "crew", "hire_date"],
                  operator_rows)
        copy_rows(cur, "location", ["name", "location_type"], LOCATIONS)
        copy_rows(cur, "component", ["parent_component_id", "name"], component_rows)
        copy_rows(cur, "shift",
                  ["shift_date", "shift_type", "crew", "start_ts", "end_ts"], shift_rows)
        copy_rows(cur, "operator_assignment",
                  ["shift_id", "operator_id", "equipment_id", "start_ts", "end_ts"],
                  assignment_rows)
        copy_rows(cur, "downtime_event",
                  ["equipment_id", "component_id", "category", "start_ts", "end_ts", "notes"],
                  downtime_rows)
        copy_rows(cur, "haul_cycle",
                  ["truck_id", "shovel_id", "operator_id", "shift_id",
                   "load_location_id", "dump_location_id", "material_type",
                   "payload_tonnes", "arrive_shovel_ts", "load_start_ts",
                   "load_end_ts", "dump_start_ts", "dump_end_ts", "cycle_end_ts"],
                  cycle_rows)
        copy_rows(cur, "fuel_event",
                  ["equipment_id", "location_id", "fuel_ts", "litres"], fuel_rows)
        cur.execute("ANALYZE")   # refresh planner statistics after a bulk load
    print("Done.")


if __name__ == "__main__":
    main()

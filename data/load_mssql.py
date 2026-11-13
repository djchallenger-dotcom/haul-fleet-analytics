"""
Copy all haul-fleet-analytics data from PostgreSQL into SQL Server.

Both databases end up with identical rows, including the same ID values,
so any query can be run on both and the results compared directly.
Re-running the script clears the SQL Server tables and reloads them.

Usage (from the repo root, with both containers running and both
schemas created):
    pip install -r requirements.txt
    python data/load_mssql.py
"""

from datetime import datetime, timedelta, timezone

import psycopg
import pyodbc

# =============================================================================
# SETTINGS
# =============================================================================
SETTINGS = {
    "postgres": "host=localhost port=55432 dbname=haul_fleet user=fleet password=fleet",
    "mssql": (
        "DRIVER={ODBC Driver 17 for SQL Server};"
        "SERVER=localhost,51433;DATABASE=haul_fleet;"
        "UID=sa;PWD=HaulFleet!2026;TrustServerCertificate=yes"
    ),
    "batch_size": 10_000,
}

# Timestamps are written in mine-local time (Arizona, UTC-7, no DST) so
# values read naturally in SQL Server. The moment in time is unchanged.
MINE_TZ = timezone(timedelta(hours=-7))

# Load order: parents before children, so every foreign key already exists.
TABLES = [
    "equipment_model",
    "equipment",
    "operator",
    "location",
    "component",
    "shift",
    "operator_assignment",
    "haul_cycle",
    "downtime_event",
    "fuel_event",
]

# Tables no foreign key points at can be emptied with the faster TRUNCATE;
# the rest need DELETE.
TRUNCATABLE = {"fuel_event", "downtime_event", "haul_cycle", "operator_assignment"}


def to_mssql(value):
    """Convert a value read from PostgreSQL into one SQL Server accepts.

    pyodbc drops the time zone from Python datetimes, so timestamps are sent
    as ISO 8601 strings with an explicit offset, which SQL Server converts to
    datetimeoffset. The format is fixed-width so every row binds the same way.
    """
    if isinstance(value, datetime):
        local = value.astimezone(MINE_TZ)
        return local.strftime("%Y-%m-%dT%H:%M:%S.%f") + "-07:00"
    return value


def column_input_sizes(ms_cur, table, columns):
    """Declare parameter sizes for text, decimal, and timestamp columns.

    With fast_executemany, pyodbc otherwise sizes these parameters from the
    first row, and a longer string or a decimal with more digits later in
    the batch would fail.
    """
    ms_cur.execute(
        """
        SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH,
               NUMERIC_PRECISION, NUMERIC_SCALE
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = ?
        """,
        table,
    )
    info = {row[0]: row[1:] for row in ms_cur.fetchall()}
    sizes = []
    for col in columns:
        dtype, length, precision, scale = info[col]
        if dtype in ("nvarchar", "varchar", "char", "nchar"):
            sizes.append((pyodbc.SQL_WVARCHAR, length, 0))
        elif dtype == "decimal":
            sizes.append((pyodbc.SQL_DECIMAL, precision, scale))
        elif dtype == "datetimeoffset":
            sizes.append((pyodbc.SQL_WVARCHAR, 40, 0))
        else:
            sizes.append(None)
    return sizes


def clear_tables(ms_cur):
    """Empty every SQL Server table, children first."""
    for table in reversed(TABLES):
        verb = "TRUNCATE TABLE" if table in TRUNCATABLE else "DELETE FROM"
        ms_cur.execute(f"{verb} {table}")


def copy_table(pg_conn, ms_conn, table):
    """Copy one table in batches, keeping the original ID values."""
    with pg_conn.cursor() as pg_cur:
        pg_cur.execute(f"SELECT * FROM {table} ORDER BY 1")
        columns = [d.name for d in pg_cur.description]

        ms_cur = ms_conn.cursor()
        ms_cur.fast_executemany = True
        sizes = column_input_sizes(ms_cur, table, columns)

        insert = (
            f"INSERT INTO {table} ({', '.join(columns)}) "
            f"VALUES ({', '.join('?' for _ in columns)})"
        )

        # Allow explicit values in the IDENTITY column so IDs match PostgreSQL
        ms_cur.execute(f"SET IDENTITY_INSERT {table} ON")
        total = 0
        while True:
            rows = pg_cur.fetchmany(SETTINGS["batch_size"])
            if not rows:
                break
            ms_cur.setinputsizes(sizes)
            ms_cur.executemany(insert, [[to_mssql(v) for v in row] for row in rows])
            total += len(rows)
        ms_cur.execute(f"SET IDENTITY_INSERT {table} OFF")
    print(f"  {table:<20} {total:>8,} rows")


def verify(pg_conn, ms_conn):
    """Compare row counts table by table."""
    print("Verifying row counts...")
    all_match = True
    ms_cur = ms_conn.cursor()
    with pg_conn.cursor() as pg_cur:
        for table in TABLES:
            pg_cur.execute(f"SELECT COUNT(*) FROM {table}")
            ms_cur.execute(f"SELECT COUNT(*) FROM {table}")
            pg_count = pg_cur.fetchone()[0]
            ms_count = ms_cur.fetchone()[0]
            status = "OK" if pg_count == ms_count else "MISMATCH"
            all_match &= pg_count == ms_count
            print(f"  {table:<20} {pg_count:>8,} {ms_count:>8,}  {status}")
    print("All tables match." if all_match else "Row counts differ; see above.")


def main():
    with psycopg.connect(SETTINGS["postgres"]) as pg_conn, \
         pyodbc.connect(SETTINGS["mssql"], autocommit=False) as ms_conn:
        print("Clearing SQL Server tables...")
        clear_tables(ms_conn.cursor())

        print("Copying from PostgreSQL to SQL Server...")
        for table in TABLES:
            copy_table(pg_conn, ms_conn, table)
        ms_conn.commit()

        verify(pg_conn, ms_conn)


if __name__ == "__main__":
    main()

import os
import sqlite3
from pathlib import Path


def add_database_args(parser):
    parser.add_argument(
        "--database-type",
        choices=("sqlite", "sqlserver", "mariadb"),
        default="sqlite",
        help="Database engine used for --db-value searches (default: sqlite).",
    )
    parser.add_argument("--database", help="SQLite database path (for --database-type sqlite).")
    parser.add_argument("--db-host", help="SQL Server or MariaDB hostname.")
    parser.add_argument("--db-port", type=int, help="Database port (default: 1433 or 3306).")
    parser.add_argument("--db-name", help="Database/catalog name for SQL Server or MariaDB.")
    parser.add_argument("--db-user", help="Database username.")
    parser.add_argument(
        "--db-password-env",
        default="DB_PASSWORD",
        help="Environment variable containing the database password (default: DB_PASSWORD).",
    )
    parser.add_argument(
        "--db-driver",
        help="SQL Server ODBC driver name (default: ODBC Driver 18 for SQL Server).",
    )


def connect_database(args):
    """Open a read-only-intended connection for the selected engine."""
    if args.database_type == "sqlite":
        if not args.database:
            raise RuntimeError("--database is required for SQLite.")
        uri = Path(args.database).resolve().as_uri() + "?mode=ro"
        conn = sqlite3.connect(uri, uri=True)
        conn.execute("PRAGMA query_only = ON")
        return conn

    password = os.environ.get(args.db_password_env) if args.db_password_env else None
    if not args.db_host or not args.db_name or not args.db_user:
        raise RuntimeError(
            f"--db-host, --db-name and --db-user are required for {args.database_type}."
        )
    if password is None:
        raise RuntimeError(
            f"Set the {args.db_password_env!r} environment variable "
            "or choose another --db-password-env name."
        )

    if args.database_type == "sqlserver":
        try:
            import pyodbc
        except ImportError as exc:
            raise RuntimeError("Install the SQL Server driver with: pip install pyodbc") from exc

        driver = args.db_driver or "ODBC Driver 18 for SQL Server"
        connection_string = (
            f"DRIVER={{{driver}}};SERVER={args.db_host},{args.db_port or 1433};"
            f"DATABASE={args.db_name};UID={args.db_user};PWD={password};"
            "Encrypt=yes;TrustServerCertificate=yes;ApplicationIntent=ReadOnly;"
        )
        conn = pyodbc.connect(connection_string, readonly=True, autocommit=False)
        return conn

    if args.database_type == "mariadb":
        try:
            import pymysql
        except ImportError as exc:
            raise RuntimeError("Install the MariaDB driver with: pip install PyMySQL") from exc

        return pymysql.connect(
            host=args.db_host,
            port=args.db_port or 3306,
            user=args.db_user,
            password=password,
            database=args.db_name,
            charset="utf8mb4",
            cursorclass=pymysql.cursors.Cursor,
            autocommit=False,
            read_timeout=30,
            write_timeout=30,
        )

    raise RuntimeError(f"Unsupported database type: {args.database_type}")


def quote_ident(s: str, dialect: str) -> str:
    """Quote one SQL identifier for the selected database."""

    if dialect == "sqlserver":
        return "[" + s.replace("]", "]]") + "]"

    if dialect == "mariadb":
        return "`" + s.replace("`", "``") + "`"

    if dialect == "sqlite":
        return '"' + s.replace('"', '""') + '"'

    raise ValueError(f"Unsupported database type: {dialect}")


def get_tables(conn, dialect):
    cursor = conn.cursor()

    if dialect == "sqlite":
        cursor.execute("""
            SELECT name
            FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
            ORDER BY name
        """)

    elif dialect == "sqlserver":
        cursor.execute("""
            SELECT TABLE_SCHEMA, TABLE_NAME
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_TYPE = 'BASE TABLE'
            ORDER BY TABLE_SCHEMA, TABLE_NAME
        """)

    elif dialect == "mariadb":
        cursor.execute("""
            SELECT TABLE_NAME
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_TYPE = 'BASE TABLE'
            ORDER BY TABLE_NAME
        """)

    else:
        raise ValueError(f"Unsupported database type: {dialect}")

    return cursor.fetchall()


def get_columns(conn, dialect, table, schema=None):
    cursor = conn.cursor()

    if dialect == "sqlite":
        quoted_table = quote_ident(table, dialect)

        cursor.execute(f"PRAGMA table_info({quoted_table})")

        return [
            {"name": row[1], "type": row[2], "nullable": not bool(row[3])}
            for row in cursor.fetchall()
        ]

    elif dialect == "mariadb":
        cursor.execute(
            """
            SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME = %s
            ORDER BY ORDINAL_POSITION
        """,
            (table,),
        )

        return [
            {"name": row[0], "type": row[1], "nullable": row[2] == "YES"}
            for row in cursor.fetchall()
        ]

    elif dialect == "sqlserver":
        cursor.execute(
            """
            SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = ?
              AND TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION
        """,
            (schema or "dbo", table),
        )

        return [
            {"name": row[0], "type": row[1], "nullable": row[2] == "YES"}
            for row in cursor.fetchall()
        ]

    else:
        raise ValueError(f"Unsupported database type: {dialect}")

    return cursor.fetchall()


def get_values(conn, dialect, table, column, schema=None):
    cursor = conn.cursor()

    quoted_table = quote_ident(table, dialect)
    quoted_column = quote_ident(column, dialect)

    if dialect == "sqlserver":
        if schema:
            quoted_table = f"{quote_ident(schema, dialect)}.{quoted_table}"

        # Convert datetimeoffset to text because pyodbc may not
        # support fetching SQL Server type -155 directly.
        cursor.execute(
            """
            SELECT DATA_TYPE
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = ?
              AND TABLE_NAME = ?
              AND COLUMN_NAME = ?
            """,
            (schema or "dbo", table, column),
        )
        metadata = cursor.fetchone()

        if metadata and metadata[0].lower() == "datetimeoffset":
            quoted_column = f"CONVERT(nvarchar(50), {quoted_column}, 127)"

    query = f"""
        SELECT {quoted_column}
        FROM {quoted_table}
    """

    cursor.execute(query)
    return [row[0] for row in cursor.fetchall()]

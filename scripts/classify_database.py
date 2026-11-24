#!/usr/bin/env python3
"""
Classify Vaultwarden SQLite columns for the persistent-storage instrument.

Only columns containing at least one non-NULL, non-empty value are included
by default. The output reports aggregate formats, not actual stored values.

Each populated column receives one thesis category:
P (plaintext personal data), S (plaintext security-relevant secret),
V (password verifier), K (wrapped/encrypted key material), C (ciphertext),
or M (metadata). The category is an evidence-based default and ambiguous
columns are explicitly marked for manual review.
"""

import argparse
import base64
import csv
import json
import re
import sqlite3
import sys
from collections import Counter
from pathlib import Path

try:
    from scripts.database import (
        add_database_args,
        connect_database,
        get_columns,
        get_tables,
        get_values,
    )
except ModuleNotFoundError:
    from database import add_database_args, connect_database, get_columns, get_tables, get_values

ENC_RE = re.compile(
    r"^\d+\.[A-Za-z0-9_+/=-]+\|[A-Za-z0-9_+/=-]+"
    r"(?:\|[A-Za-z0-9_+/=-]+)?$"
)
PGP_MESSAGE_RE = re.compile(
    r"\A-----BEGIN PGP MESSAGE-----.*?-----END PGP MESSAGE-----\Z", re.DOTALL
)
PGP_PUBLIC_KEY_RE = re.compile(
    r"\A-----BEGIN PGP PUBLIC KEY BLOCK-----.*?-----END PGP PUBLIC KEY BLOCK-----\Z", re.DOTALL
)
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(?:[ T].*)?$")
BASE32_RE = re.compile(r"^[A-Z2-7]{16,}$", re.IGNORECASE)
OTPAUTH_RE = re.compile(r"otpauth://(?:totp|hotp)/[^?\s]+\?.*?secret=([A-Z2-7]+)", re.IGNORECASE)

BINARY_TYPES = {"BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "BINARY", "VARBINARY", "IMAGE"}
DATETIME_TYPES = {"DATE", "DATETIME", "DATETIME2", "SMALLDATETIME", "TIME"}
INTEGER_TYPES = {"INT", "INTEGER", "SMALLINT", "TINYINT", "BIGINT", "MEDIUMINT", "SERIAL"}
BOOLEAN_TYPES = {"BIT", "BOOLEAN", "BOOL"}
NUMERIC_TYPES = {"FLOAT", "DOUBLE", "REAL", "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY"}


def normalize_type(data_type):
    """Remove length and precision specifications from a database type."""
    return data_type.upper().split("(", 1)[0].strip()


def value_format(value, data_type, dialect):
    if value is None:
        return "NULL"

    data_type = normalize_type(data_type)

    # SQL Server TIMESTAMP is a rowversion value, not a date/time.
    if dialect == "sqlserver" and data_type in {"TIMESTAMP", "ROWVERSION"}:
        return "BINARY"

    # SQLite uses flexible storage classes, so inspect the actual value first.
    if dialect == "sqlite":
        if isinstance(value, bytes):
            return "BINARY"
        if isinstance(value, bool):
            return "BOOLEAN"
        if isinstance(value, (int, float)):
            return "NUMERIC"

    # Use declared types for SQL Server and MariaDB.
    if data_type in BINARY_TYPES:
        return "BINARY"

    if data_type in BOOLEAN_TYPES:
        return "BOOLEAN"

    if data_type in DATETIME_TYPES:
        return "DATETIME"

    if dialect == "mariadb" and data_type == "TIMESTAMP":
        return "DATETIME"

    if data_type in INTEGER_TYPES or data_type in NUMERIC_TYPES:
        return "NUMERIC"

    # Inspect the actual value if the declared type was inconclusive.
    return check_value_format(value)


def check_value_format(value):
    if isinstance(value, bytes):
        return "BINARY"

    if isinstance(value, bool):
        return "BOOLEAN"

    if isinstance(value, (int, float)):
        return "NUMERIC"

    if not isinstance(value, str):
        return "OTHER"

    s = value.strip()

    if not s:
        return "EMPTY"

    patterns = (
        (ENC_RE, "ENCRYPTED_FORMAT_CANDIDATE"),
        (PGP_MESSAGE_RE, "PGP_ENCRYPTED_MESSAGE"),
        (PGP_PUBLIC_KEY_RE, "PGP_PUBLIC_KEY"),
        (UUID_RE, "UUID"),
        (EMAIL_RE, "EMAIL"),
        (TIMESTAMP_RE, "TIMESTAMP"),
    )

    for pattern, result in patterns:
        if pattern.fullmatch(s):
            return result

    try:
        json.loads(s)
        return "JSON"
    except (ValueError, TypeError):
        return "READABLE_TEXT"


def is_ambiguous_base32(value):
    """Check whether a string could be a Base32-encoded secret."""
    if not isinstance(value, str):
        return False

    s = value.strip().replace(" ", "").upper()

    if not BASE32_RE.fullmatch(s):
        return False

    try:
        base64.b32decode(s + "=" * ((8 - len(s) % 8) % 8))
        return True
    except Exception:  # noqa: BLE001
        return False


def inspect_json(obj, categories=None, otp_context=False):
    if categories is None:
        categories = Counter()

    if isinstance(obj, dict):
        for key, value in obj.items():
            key_lower = str(key).lower()

            if "recovery" in key_lower:
                categories["RECOVERY_FIELD_CANDIDATE"] += 1

            if "setting" in key_lower or "option" in key_lower:
                categories["SETTING_OR_OPTION_FIELD_CANDIDATE"] += 1

            child_otp_context = otp_context or "otp" in key_lower

            # Name field with readable text
            if (
                "name" in key_lower
                and isinstance(value, str)
                and check_value_format(value) == "READABLE_TEXT"
            ):
                categories["READABLE_NAME"] += 1

            inspect_json(value, categories, child_otp_context)

    elif isinstance(obj, list):
        for value in obj:
            inspect_json(value, categories, otp_context)

    elif isinstance(obj, str):
        value = obj.strip()

        if EMAIL_RE.fullmatch(value):
            categories["EMAIL"] += 1

        if ENC_RE.fullmatch(value):
            categories["ENCRYPTED_FORMAT_CANDIDATE"] += 1

        if PGP_MESSAGE_RE.fullmatch(value):
            categories["PGP_ENCRYPTED_MESSAGE"] += 1

        otp_match = OTPAUTH_RE.search(value)

        if otp_match or otp_context and is_ambiguous_base32(value):
            categories["OTP_SECRET_CANDIDATE"] += 1

    return categories


def categorize_json(json_string):
    try:
        obj = json.loads(json_string)
    except (ValueError, TypeError):
        return Counter({"INVALID_JSON": 1})

    categories = inspect_json(obj)

    if not categories:
        categories["Could not determine a category needs manual validation"] = 1

    return categories


def classify_json_categories(categories) -> tuple[str, str]:
    parts = []
    found = []

    encrypted = categories["ENCRYPTED_FORMAT_CANDIDATE"]
    pgp = categories["PGP_ENCRYPTED_MESSAGE"]
    otp = categories["OTP_SECRET_CANDIDATE"]
    emails = categories["EMAIL"]
    settings = categories["SETTING_OR_OPTION_FIELD_CANDIDATE"]
    recovery = categories["RECOVERY_FIELD_CANDIDATE"]
    names = categories["READABLE_NAME"]

    # Encrypted content
    if encrypted:
        parts.append(f"{encrypted} EncString candidates")
        found.append("C")

    if pgp:
        parts.append(f"{pgp} PGP messages")
        found.append("C")

    # Personal information
    if emails:
        parts.append(f"{emails} email addresses")
        found.append("P")

    if names:
        parts.append(f"{names} readable name values")
        found.append("P")

    # Security-related content
    if otp:
        parts.append(f"{otp} OTP secret candidates")
        found.append("S")

    if recovery:
        parts.append(f"{recovery} recovery-related fields")
        found.append("S")

    # Application metadata
    if settings:
        parts.append(f"{settings} setting/option fields")
        found.append("M")

    if not parts:
        return "M", "JSON content could not be categorized; manual validation required."

    # Remove duplicate categories while preserving order
    category = "&".join(dict.fromkeys(found)) if found else "M"

    note = "JSON content contains: " + ", ".join(parts)
    if any(category in found for category in ("C", "S", "K")):
        note += "; candidates not verified"
    else:
        note += "."

    return category, note


def thesis_category(column, json_categories, formats):
    """Classify a column using all observed formats and limited schema hints."""

    lowered = column.lower()

    populated_formats = {
        fmt: count for fmt, count in formats.items() if fmt not in {"NULL", "EMPTY"} and count > 0
    }

    if not populated_formats:
        return "UNCLASSIFIED", "No populated value available for classification."

    # Limited schema-based hints.
    personal_data = {"email", "name", "username", "password_hint", "hint", "file_name"}

    if lowered in personal_data and "READABLE_TEXT" in formats:
        return "P", "Potential personal information based on column name; not verified."

    if lowered in {"password_hash", "salt"} or lowered.endswith("_password_hash"):
        return "V", "Potential password verifier or salt based on column name; not verified."

    if lowered in {"twofactor_secret", "two_factor_secret", "api_key", "client_secret"}:
        return "S", "Potential security-related secret based on column name; not verified."

    if lowered in {"akey", "key", "private_key", "wrapped_key", "encrypted_key", "master_key"}:
        if "ENCRYPTED_FORMAT_CANDIDATE" not in formats:
            return "K", "Potential key material based on column name; not verified."
        return (
            "K",
            "Potential encrypted key material based on column name and observed_format; not verified.",
        )

    if lowered.endswith("_token") or lowered in {"token", "secret", "password"}:
        return "S", "Potential authentication material based on column name; not verified."

    if "public" in lowered or "PGP_PUBLIC_KEY" in formats:
        return (
            "M",
            "Potential public key material based on column name and observed_format; not verified.",
        )
    if "kdf_" in lowered or "Kdf" in column:
        return "S", "Potential KDF Algorithm relevant value based on column name; not verified."

    categories = set()
    notes = []

    format_categories = {
        "ENCRYPTED_FORMAT_CANDIDATE": "C",
        "PGP_ENCRYPTED_MESSAGE": "C",
        "EMAIL": "P",
        "UUID": "M",
        "TIMESTAMP": "M",
        "DATETIME": "M",
        "NUMERIC": "M",
        "BOOLEAN": "M",
        "READABLE_TEXT": "M",
        "BINARY": "UNCLASSIFIED",
        "OTHER": "UNCLASSIFIED",
    }

    for observed_format in populated_formats:
        if observed_format == "JSON":
            json_category, json_note = classify_json_categories(json_categories)
            categories.update(json_category.split("&"))
            notes.append(json_note)
        else:
            category = format_categories.get(observed_format, "M")
            categories.add(category)

            if observed_format == "ENCRYPTED_FORMAT_CANDIDATE":
                notes.append(
                    "EncString-shaped value; purpose and cryptographic protection not verified."
                )

            elif observed_format == "BINARY":
                notes.append("Binary data; purpose cannot be determined from representation alone.")

    category = "&".join(sorted(categories)) if categories else "UNCLASSIFIED"

    if len(categories) > 1:
        notes.append("Multiple thesis categories detected; manual review required.")

    if not notes:
        notes.append(
            "Classification based on observed value formats; purpose not independently verified."
        )

    return category, " ".join(notes)


def assess(table, column, values, data_type, dialect, formats: Counter[str]):
    json_categories = Counter()

    for value in values:
        if value_format(value, data_type, dialect) == "JSON":
            json_categories.update(categorize_json(value))

    category, category_note = thesis_category(column, json_categories, formats)

    populated = [
        value
        for value in values
        if value is not None and not (isinstance(value, str) and not value.strip())
    ]

    populated_formats = {
        fmt: count for fmt, count in formats.items() if fmt not in {"NULL", "EMPTY"} and count > 0
    }

    notes = [category_note]

    # A mixture of formats may indicate that one column contains
    # more than one kind of value.
    if len(populated_formats) > 1:
        notes.append("Mixed value formats; classification based on the most common format.")

    if formats["ENCRYPTED_FORMAT_CANDIDATE"]:
        notes.append("EncString-shaped format is not proof of cryptographic protection.")

    if column.lower() == "password_hash":
        notes.append("Hashing is distinct from reversible encryption.")

    notes_text = " ".join(notes)

    manual_review = (
        category == "UNCLASSIFIED"
        or "&" in category
        or "not verified" in notes_text.lower()
        or "manual validation required" in notes_text.lower()
        or "manual review required" in notes_text.lower()
        or "cannot be determined" in notes_text.lower()
    )

    return {
        "table": table,
        "column": column,
        "declared_type": data_type,
        "category": category,
        "needs_manual_review": "yes" if manual_review else "no",
        "rows_with_data": len(populated),
        "observed_formats": "; ".join(sorted(fmt for fmt, count in formats.items() if count > 0)),
        "notes": notes_text,
    }


def classify(args, include_empty=False):

    output = []
    dialect = args.database_type
    conn = connect_database(args)

    try:
        tables = get_tables(conn, dialect)

        for table_info in tables:
            if dialect == "sqlserver":
                schema_name, table = table_info
            else:
                table = table_info[0]
                schema_name = None

            columns = get_columns(conn, dialect, table, schema_name)

            for column_info in columns:
                column = column_info["name"]
                data_type = column_info["type"]

                values = get_values(conn, dialect, table, column, schema_name)

                formats = Counter(value_format(v, data_type, dialect) for v in values)
                populated = [
                    v
                    for v in values
                    if v is not None and not (isinstance(v, str) and not v.strip())
                ]

                if not populated and not include_empty:
                    continue

                output.append(assess(table, column, values, data_type, dialect, formats))

        return output

    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="../artifacts/column_classification.csv")
    parser.add_argument(
        "--include-empty",
        action="store_true",
        help="Include columns with no non-NULL, non-empty values.",
    )
    add_database_args(parser)
    args = parser.parse_args()

    try:
        rows = classify(args, args.include_empty)

        fields = [
            "table",
            "column",
            "declared_type",
            "category",
            "needs_manual_review",
            "rows_with_data",
            "observed_formats",
            "notes",
        ]

        with Path(args.output).open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

        print(f"Populated columns classified: {len(rows)}")
        print(f"CSV written: {args.output}")

    except (OSError, sqlite3.Error, RuntimeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

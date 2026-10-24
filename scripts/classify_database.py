#!/usr/bin/env python3
"""
Concise SQLite data inventory for password-manager persistent storage.

Only columns containing at least one non-NULL, non-empty value are included
by default. The output reports aggregate formats, not actual stored values.

Protection labels are cautious: observed formats alone cannot prove that
a value is encrypted or that its encryption is secure.
"""

import argparse
import collections
import csv
import json
import re
import sqlite3
import sys
from pathlib import Path

ENC_RE = re.compile(
    r"^\d+\.[A-Za-z0-9_+/=-]+\|[A-Za-z0-9_+/=-]+"
    r"(?:\|[A-Za-z0-9_+/=-]+)?$"
)
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(?:[ T].*)?$")


# These are schema-informed starting points, not universal truths.
# Confirm them against the exact application/version under test.
ROLE_MAP = {
    "users": {
        "email": ("Account email", "Plaintext metadata (verify observed values)"),
        "name": ("Account display name", "Plaintext metadata (verify observed values)"),
        "password_hash": (
            "Master-password verification hash",
            "Password hash; not reversible encryption",
        ),
        "salt": ("Password-hashing salt", "Hashing parameter; not a password"),
        "private_key": ("User private-key material", "Protection must be verified"),
        "public_key": ("User public key", "Public-key material; not secret by itself"),
        "password_hint": ("Master-password hint", "Potentially plaintext; verify observed values"),
        "hint": (
            "Password hint or related metadata",
            "Potentially plaintext; verify schema meaning",
        ),
    },
    "ciphers": {
        "uuid": ("Item identifier", "Identifier; not secret by itself"),
        "user_uuid": ("Owner user identifier", "Identifier; not secret by itself"),
        "organization_uuid": ("Organization identifier", "Identifier; not secret by itself"),
        "name": ("Item name", "Check observed format and application semantics"),
        "notes": ("Item notes", "Check observed format and application semantics"),
        "data": (
            "Structured cipher payload",
            "Inspect nested fields; outer JSON does not determine field protection",
        ),
        "fields": ("Custom item fields", "Check observed format and application semantics"),
        "password_history": ("Password history", "Check observed format and application semantics"),
    },
    "attachments": {
        "file_name": ("Attachment filename", "Check observed format and application semantics"),
        "akey": ("Attachment key material", "Potentially sensitive; verify application semantics"),
        "file_size": ("Attachment size", "Numeric metadata; not encrypted by itself"),
    },
    "organizations": {
        "name": ("Organization name", "Check observed format and application semantics"),
    },
    "folders": {
        "name": ("Folder name", "Check observed format and application semantics"),
    },
}


def quote_ident(value):
    return '"' + value.replace('"', '""') + '"'


def value_format(value):
    if value is None:
        return "NULL"
    if isinstance(value, bytes):
        return "BINARY"
    if isinstance(value, (int, float)):
        return "NUMERIC"
    if not isinstance(value, str):
        return "OTHER"

    s = value.strip()
    if not s:
        return "EMPTY"
    if ENC_RE.fullmatch(s):
        return "ENCRYPTED_FORMAT_CANDIDATE"
    if UUID_RE.fullmatch(s):
        return "UUID"
    if EMAIL_RE.fullmatch(s):
        return "EMAIL"
    if TIMESTAMP_RE.fullmatch(s):
        return "TIMESTAMP"

    try:
        json.loads(s)
        return "JSON"
    except (ValueError, TypeError):
        return "READABLE_TEXT"


def assess(table, column, values, formats):
    role, assessment = ROLE_MAP.get(table, {}).get(
        column,
        ("Unknown; inspect schema and application use", "Unknown"),
    )

    populated_formats = {
        key: count for key, count in formats.items() if key not in {"NULL", "EMPTY"} and count
    }

    if assessment == "Unknown" and populated_formats:
        labels = set(populated_formats)
        if labels == {"ENCRYPTED_FORMAT_CANDIDATE"}:
            assessment = "Encrypted-format candidate; verify application semantics"
        elif labels.issubset({"READABLE_TEXT", "EMAIL", "UUID", "TIMESTAMP", "NUMERIC"}):
            assessment = "Readable/structured values observed; verify data meaning"
        elif "ENCRYPTED_FORMAT_CANDIDATE" in labels:
            assessment = "Mixed formats; investigate each format"
        elif "BINARY" in labels:
            assessment = "Binary data; encryption status unknown"

    if table == "ciphers" and column == "data":
        role = "Structured cipher payload"
        assessment = "Mixed/nested fields possible; inspect JSON fields individually"

    notes = ""
    if "ENCRYPTED_FORMAT_CANDIDATE" in formats:
        notes = "Format match is not proof of cryptographic protection."
    if assessment == "Unknown":
        notes = "Column name and value pattern are insufficient to determine protection."
    if column == "password_hash":
        notes = "Hashing is distinct from reversible encryption."

    return {
        "table": table,
        "column": column,
        "rows_with_data": sum(
            1 for v in values if v is not None and not (isinstance(v, str) and not v.strip())
        ),
        "data_role": role,
        "protection_assessment": assessment,
        "observed_formats": "; ".join(f"{k}={v}" for k, v in sorted(populated_formats.items())),
        "encrypted_format_count": formats.get("ENCRYPTED_FORMAT_CANDIDATE", 0),
        "plaintext_format_count": sum(
            formats.get(k, 0) for k in ("READABLE_TEXT", "EMAIL", "UUID", "TIMESTAMP")
        ),
        "notes": notes,
    }


def classify(database, include_empty=False):
    uri = Path(database).resolve().as_uri() + "?mode=ro"
    output = []

    with sqlite3.connect(uri, uri=True) as conn:
        conn.execute("PRAGMA query_only = ON")
        tables = conn.execute("""
            SELECT name FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
        """).fetchall()

        for (table,) in tables:
            qtable = quote_ident(table)
            schema = conn.execute(f"PRAGMA table_info({qtable})").fetchall()

            for info in schema:
                column = info[1]
                qcolumn = quote_ident(column)
                values = [row[0] for row in conn.execute(f"SELECT {qcolumn} FROM {qtable}")]

                formats = collections.Counter(value_format(v) for v in values)
                populated = [
                    v
                    for v in values
                    if v is not None and not (isinstance(v, str) and not v.strip())
                ]

                if not populated and not include_empty:
                    continue

                output.append(assess(table, column, values, formats))

    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", help="Path to SQLite database")
    parser.add_argument("--output", default="column_classification.csv")
    parser.add_argument(
        "--include-empty",
        action="store_true",
        help="Include columns with no non-NULL, non-empty values.",
    )
    args = parser.parse_args()

    try:
        rows = classify(args.database, args.include_empty)
        fields = [
            "table",
            "column",
            "rows_with_data",
            "data_role",
            "protection_assessment",
            "observed_formats",
            "encrypted_format_count",
            "plaintext_format_count",
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

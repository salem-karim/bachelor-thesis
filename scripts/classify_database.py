#!/usr/bin/env python3
"""
Classify Vaultwarden SQLite columns for the persistent-storage instrument.

Only columns containing at least one non-NULL, non-empty value are included
by default. The output reports aggregate formats, not actual stored values.

Each populated column receives one thesis category:
P (plaintext personal data), S (plaintext security-relevant secret),
V (password verifier), K (wrapped/encrypted key material), C (ciphertext),
or M (metadata). The category is an evidence-based default and ambiguous
or mixed columns are explicitly marked for manual review.
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

COMMON_COLUMN_MAP = {
    "created_at": ("Creation timestamp", "Readable metadata; not secret by itself"),
    "updated_at": ("Last-update timestamp", "Readable metadata; not secret by itself"),
    "deleted_at": ("Deletion timestamp", "Readable metadata; not secret by itself"),
    "id": ("Record identifier", "Identifier; not secret by itself"),
    "uuid": ("Record identifier", "Identifier; not secret by itself"),
    "email": ("Email address", "Potentially plaintext personal data; verify observed values"),
    "username": ("Username", "Potentially plaintext account metadata"),
    "status": ("Status or state", "Application metadata; not secret by itself"),
    "type": ("Type discriminator", "Application metadata; not secret by itself"),
    "atype": ("Type discriminator", "Application metadata; not secret by itself"),
    "enabled": ("Enabled/disabled flag", "Application metadata; not secret by itself"),
    "name": ("Display or resource name", "Check observed format and application semantics"),
    "description": ("Description metadata", "Check observed format and application semantics"),
    "url": ("URL metadata", "Check observed format and application semantics"),
    "refresh_token": ("Refresh token", "Sensitive bearer credential; treat as secret"),
    "access_token": ("Access token", "Sensitive bearer credential; treat as secret"),
    "token": ("Authentication or session token", "Potentially sensitive bearer credential"),
    "password": ("Password or password payload", "Secret; protection must be verified"),
    "password_hash": ("Password verification hash", "Password hash; not reversible encryption"),
    "salt": ("Password-hashing salt", "Hashing parameter; not a password"),
    "secret": ("Secret material", "Sensitive; protection must be verified"),
    "private_key": ("Private-key material", "Sensitive key material; protection must be verified"),
    "public_key": ("Public-key material", "Public-key material; not secret by itself"),
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


def contains_encstring(value):
    """Return whether a value or nested JSON value contains EncString text."""
    if isinstance(value, str):
        if ENC_RE.fullmatch(value.strip()):
            return True
        try:
            value = json.loads(value)
        except (ValueError, TypeError):
            return False
    if isinstance(value, dict):
        return any(contains_encstring(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_encstring(item) for item in value)
    return False


def thesis_category(table, column, values, formats):
    """Assign the six-category thesis classification from schema and values."""
    lowered = column.lower()
    table_lowered = table.lower()
    nonempty = [v for v in values if v is not None and not (isinstance(v, str) and not v.strip())]
    encrypted_count = sum(contains_encstring(v) for v in nonempty)
    readable_formats = {"READABLE_TEXT", "EMAIL", "UUID", "TIMESTAMP", "JSON", "NUMERIC"}

    if lowered in {"password_hash", "salt"} or lowered.endswith("_password_hash"):
        return "V", "Server-side password verifier or its salt."
    if any(token in lowered for token in ("private_key", "wrapped_key", "encrypted_key", "master_key")):
        return "K", "Key material; verify whether the observed representation is wrapped/encrypted."
    if lowered in {"twofactor_secret", "two_factor_secret", "api_key", "client_secret"}:
        return "S", "Plaintext security-relevant secret by schema meaning."
    if lowered.endswith("_token") or lowered in {"token", "secret", "password", "password_hint", "hint"}:
        return "S" if lowered not in {"password_hint", "hint"} else "P", "Sensitive plaintext field; verify application semantics."
    if table_lowered == "ciphers" and lowered in {"data", "fields", "password_history", "notes"}:
        return "C", "Vault item contents; nested EncString fields are ciphertext."
    if encrypted_count and encrypted_count == len(nonempty):
        return "C", "All populated values contain EncString-shaped ciphertext."
    if encrypted_count:
        return "C", "Mixed column; some values contain EncString-shaped ciphertext."
    if lowered in {"email", "name", "username", "password_hint", "hint", "file_name"}:
        return "P", "Plaintext personal or account data."
    if set(formats) & readable_formats:
        return "M", "Readable identifier, lifecycle, or application metadata."
    if "BINARY" in formats:
        return "K", "Binary key material candidate; confirm against schema and application use."
    return "M", "No stronger category was established from schema or observed format."


def column_role(table, column):
    role_assessment = ROLE_MAP.get(table, {}).get(column)
    if role_assessment:
        return role_assessment
    if column in COMMON_COLUMN_MAP:
        return COMMON_COLUMN_MAP[column]
    if column.endswith("_uuid") or column.endswith("_id"):
        return ("Related-record identifier", "Identifier; not secret by itself")
    if column.endswith("_at") or column.endswith("_on"):
        return ("Lifecycle timestamp", "Readable metadata; not secret by itself")
    if column.endswith("_token") or column.endswith("_key"):
        return ("Sensitive credential or key material", "Sensitive; protection must be verified")
    return ("Unknown; inspect schema and application use", "Unknown")


def assess(table, column, values, formats):
    role, assessment = column_role(table, column)
    category, category_note = thesis_category(table, column, values, formats)

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

    mixed_formats = len(populated_formats) > 1
    manual_review = mixed_formats or category in {"K", "C"} and (
        "verify" in category_note.lower() or "mixed" in category_note.lower()
    )
    notes = category_note
    if "ENCRYPTED_FORMAT_CANDIDATE" in formats:
        notes = "Format match is not proof of cryptographic protection."
    if assessment == "Unknown":
        notes = "Column name and value pattern are insufficient to determine protection."
    if column == "password_hash":
        notes = "Hashing is distinct from reversible encryption."

    return {
        "table": table,
        "column": column,
        "category": category,
        "manual_review": "yes" if manual_review else "no",
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
            "category",
            "manual_review",
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

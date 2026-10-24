#!/usr/bin/env python3
"""
Repeatable, read-only memory analysis for password-manager core dumps.

For each core dump this script:
  1. extracts strings with `strings -a -n N | LC_ALL=C sort -u`;
  2. runs GNU diff (NOT comm) against a selected baseline;
  3. optionally runs a diff against the preceding dump;
  4. searches for exact marker strings from marker_log.csv;
  5. optionally searches selected SQLite column values (e.g. password hash,
     salt) in raw, hex, and Base64 representations;
  6. optionally counts JWT-like token patterns without writing token contents.

It does not modify core dumps or the database. CSV output contains counts and
metadata, not recovered marker/JWT contents.
"""

import argparse
import base64
import csv
import hashlib
import mmap
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

JWT_RE = re.compile(rb"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}")


def run_sort_strings(core: Path, output: Path, min_length: int) -> None:
    strings_cmd = shutil.which("strings")
    sort_cmd = shutil.which("sort")
    if not strings_cmd or not sort_cmd:
        raise RuntimeError("Required commands not found: install binutils and coreutils.")

    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_suffix(output.suffix + ".unsorted.tmp")
    env = {**os.environ, "LC_ALL": "C"}

    try:
        with tmp.open("wb") as out:
            proc = subprocess.run(
                [strings_cmd, "-a", "-n", str(min_length), str(core)],
                stdout=out,
                stderr=subprocess.PIPE,
                env=env,
                check=False,
            )
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode("utf-8", "replace")[:1000])

        with tmp.open("rb") as src, output.open("wb") as dst:
            proc = subprocess.run(
                [sort_cmd, "-u"],
                stdin=src,
                stdout=dst,
                stderr=subprocess.PIPE,
                env=env,
                check=False,
            )
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode("utf-8", "replace")[:1000])
    finally:
        tmp.unlink(missing_ok=True)


def run_diff_new_lines(old_file: Path, new_file: Path, output_file: Path) -> int:
    """
    Reproduce the user's GNU diff approach: output only lines in new_file
    that are not present in old_file. Inputs are already sorted with LC_ALL=C.
    """
    env = {**os.environ, "LC_ALL": "C"}
    command = [
        shutil.which("diff") or "diff",
        "--old-group-format=",
        "--new-group-format=%>",
        "--changed-group-format=%>",
        "--unchanged-group-format=",
        str(old_file),
        str(new_file),
    ]
    with output_file.open("wb") as out:
        proc = subprocess.run(command, stdout=out, stderr=subprocess.PIPE, env=env, check=False)

    # GNU diff exit code 0 means identical; 1 means differences; >1 means error.
    if proc.returncode not in (0, 1):
        raise RuntimeError(proc.stderr.decode("utf-8", "replace")[:1000])

    with output_file.open("rb") as handle:
        count = sum(1 for _ in handle)
    return count


def parse_scenario(filename: str) -> str:
    m = re.search(r"_(S\d+)_core", filename)
    return m.group(1) if m else "unknown"


def parse_run(filename: str) -> str:
    # Example: 20261024T083340Z_S7_core_.117491
    m = re.search(r"(\d+)$", filename)
    return m.group(1) if m else ""


def read_markers(path: Path | None) -> list[dict]:
    if path is None:
        return []
    markers = []
    with path.open("r", newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        required = {"label", "marker"}
        if not reader.fieldnames or not required.issubset(reader.fieldnames):
            raise RuntimeError("Marker CSV must contain at least label and marker columns.")
        for row in reader:
            value = (row.get("marker") or "").strip()
            if value:
                markers.append(
                    {
                        "label": (row.get("label") or "unknown").strip(),
                        "marker": value.encode("utf-8"),
                    }
                )
    return markers


def quote_ident(s: str) -> str:
    return '"' + s.replace('"', '""') + '"'


def read_db_values(db_path: Path | None, specs: list[str]) -> list[dict]:
    """
    Read selected values from a SQLite DB read-only.
    Each --db-value must be TABLE.COLUMN. If a column has multiple populated
    rows, each value is searched and identified by a stable value hash, not
    by printing the value itself.
    """
    if not specs:
        return []
    if db_path is None:
        raise RuntimeError("--db-value requires --database.")

    uri = db_path.resolve().as_uri() + "?mode=ro"
    result = []

    with sqlite3.connect(uri, uri=True) as conn:
        conn.execute("PRAGMA query_only = ON")
        for spec in specs:
            if "." not in spec:
                raise RuntimeError(f"Invalid --db-value {spec!r}; use TABLE.COLUMN.")
            table, column = spec.split(".", 1)
            qtable, qcolumn = quote_ident(table), quote_ident(column)

            table_exists = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                (table,),
            ).fetchone()
            if not table_exists:
                raise RuntimeError(f"Table not found in database: {table}")

            columns = {r[1] for r in conn.execute(f"PRAGMA table_info({qtable})")}
            if column not in columns:
                raise RuntimeError(f"Column not found: {table}.{column}")

            rows = conn.execute(
                f"SELECT {qcolumn} FROM {qtable} WHERE {qcolumn} IS NOT NULL"
            ).fetchall()

            for index, (value,) in enumerate(rows, start=1):
                if isinstance(value, bytes):
                    raw = value
                elif isinstance(value, str):
                    raw = value.encode("utf-8")
                elif isinstance(value, (int, float)):
                    raw = str(value).encode("ascii")
                else:
                    continue

                if not raw:
                    continue

                result.append(
                    {
                        "label": f"db:{table}.{column}:row{index}",
                        "bytes": raw,
                        "length": len(raw),
                        "sha256": hashlib.sha256(raw).hexdigest(),
                    }
                )

    return result


def find_all(mm, pattern: bytes) -> list[int]:
    if not pattern:
        return []
    positions = []
    start = 0
    while True:
        pos = mm.find(pattern, start)
        if pos < 0:
            break
        positions.append(pos)
        start = pos + 1
    return positions


def marker_search(core: Path, markers: list[dict]) -> list[dict]:
    rows = []
    if core.stat().st_size == 0:
        return rows

    with core.open("rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        for item in markers:
            offsets = find_all(mm, item["marker"])
            rows.append(
                {
                    "marker_label": item["label"],
                    "marker_length_bytes": len(item["marker"]),
                    "exact_matches": len(offsets),
                    "first_offset_hex": f"0x{offsets[0]:x}" if offsets else "",
                }
            )
    return rows


def database_value_search(core: Path, db_values: list[dict]) -> list[dict]:
    rows = []
    if not db_values or core.stat().st_size == 0:
        return rows

    with core.open("rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        for item in db_values:
            raw = item["bytes"]
            variants = {
                "raw": raw,
                "hex_lower": raw.hex().encode("ascii"),
                "hex_upper": raw.hex().upper().encode("ascii"),
                "base64": base64.b64encode(raw),
                "base64_no_padding": base64.b64encode(raw).rstrip(b"="),
            }
            for representation, pattern in variants.items():
                offsets = find_all(mm, pattern)
                rows.append(
                    {
                        "db_value_label": item["label"],
                        "value_length_bytes": item["length"],
                        "value_sha256": item["sha256"],
                        "representation": representation,
                        "match_count": len(offsets),
                        "first_offset_hex": f"0x{offsets[0]:x}" if offsets else "",
                        "interpretation_note": (
                            "Short values can match by chance; interpret in context."
                            if item["length"] < 16
                            else ""
                        ),
                    }
                )
    return rows


def jwt_search(core: Path) -> dict:
    """Count JWT-like ASCII patterns and offsets, without recording token text."""
    result = {"jwt_like_count": 0, "jwt_first_offset_hex": ""}
    if core.stat().st_size == 0:
        return result

    with core.open("rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        count = 0
        first_offset = None
        for match in JWT_RE.finditer(mm):
            count += 1
            if first_offset is None:
                first_offset = match.start()
        result["jwt_like_count"] = count
        if first_offset is not None:
            result["jwt_first_offset_hex"] = f"0x{first_offset:x}"
    return result


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--core-dir", default=".", help="Directory containing core dumps.")
    p.add_argument("--pattern", default="*_core*", help="Glob pattern for core dump filenames.")
    p.add_argument(
        "--strings-dir", default="strings", help="Directory for extracted sorted strings."
    )
    p.add_argument("--diff-dir", default="diffs", help="Directory for diff output files.")
    p.add_argument("--baseline", help="Baseline strings file (e.g. strings/S1_sorted.txt).")
    p.add_argument("--min-string-length", type=int, default=8)
    p.add_argument(
        "--markers", default="marker_log.csv", help="Marker CSV; use --no-markers to disable."
    )
    p.add_argument("--no-markers", action="store_true")
    p.add_argument("--database", help="Optional SQLite database path for database-value searches.")
    p.add_argument(
        "--db-value",
        action="append",
        default=[],
        help="SQLite value to search, as TABLE.COLUMN; repeat for multiple columns.",
    )
    p.add_argument("--output", default="memory_analysis.csv")
    p.add_argument("--marker-output", default="marker_search.csv")
    p.add_argument("--db-search-output", default="database_value_search.csv")
    p.add_argument("--jwt-output", default="jwt_search.csv")
    args = p.parse_args()

    core_dir = Path(args.core_dir)
    strings_dir = Path(args.strings_dir)
    diff_dir = Path(args.diff_dir)
    strings_dir.mkdir(parents=True, exist_ok=True)
    diff_dir.mkdir(parents=True, exist_ok=True)

    if args.min_string_length < 1:
        p.error("--min-string-length must be positive.")

    diff_cmd = shutil.which("diff")
    if not diff_cmd:
        p.error("GNU diff is required.")

    baseline = Path(args.baseline) if args.baseline else None
    if baseline and not baseline.is_file():
        p.error(f"Baseline file not found: {baseline}")

    marker_path = None if args.no_markers else Path(args.markers)
    if marker_path and not marker_path.is_file():
        p.error(f"Marker CSV not found: {marker_path}")

    try:
        markers = read_markers(marker_path)
        db_values = read_db_values(
            Path(args.database) if args.database else None,
            args.db_value,
        )
    except Exception as exc:
        p.error(str(exc))

    cores = sorted(path for path in core_dir.glob(args.pattern) if path.is_file())
    if not cores:
        p.error(f"No files matched {args.pattern!r} in {core_dir}")

    main_rows, marker_rows, db_rows, jwt_rows = [], [], [], []
    previous_strings = None

    for i, core in enumerate(cores, 1):
        print(f"[{i}/{len(cores)}] {core.name}", flush=True)
        strings_file = strings_dir / f"{core.name}.txt"
        row = {
            "core_file": core.name,
            "scenario": parse_scenario(core.name),
            "run_id": parse_run(core.name),
            "core_size_bytes": core.stat().st_size,
            "strings_file": str(strings_file),
            "status": "ok",
            "baseline_diff_file": "",
            "baseline_new_strings": "",
            "previous_diff_file": "",
            "previous_new_strings": "",
            "error": "",
        }

        try:
            run_sort_strings(core, strings_file, args.min_string_length)

            if baseline:
                diff_path = diff_dir / f"{core.name}.vs_baseline.new.txt"
                count = run_diff_new_lines(baseline, strings_file, diff_path)
                row["baseline_diff_file"] = str(diff_path)
                row["baseline_new_strings"] = count

            if previous_strings is not None:
                diff_path = diff_dir / f"{core.name}.vs_previous.new.txt"
                count = run_diff_new_lines(previous_strings, strings_file, diff_path)
                row["previous_diff_file"] = str(diff_path)
                row["previous_new_strings"] = count

            previous_strings = strings_file

            for found in marker_search(core, markers):
                marker_rows.append(
                    {
                        "core_file": core.name,
                        "scenario": row["scenario"],
                        "run_id": row["run_id"],
                        **found,
                    }
                )

            for found in database_value_search(core, db_values):
                db_rows.append(
                    {
                        "core_file": core.name,
                        "scenario": row["scenario"],
                        "run_id": row["run_id"],
                        **found,
                    }
                )

            jwt_rows.append(
                {
                    "core_file": core.name,
                    "scenario": row["scenario"],
                    "run_id": row["run_id"],
                    **jwt_search(core),
                }
            )

        except Exception as exc:
            row["status"] = "error"
            row["error"] = str(exc)[:1000]
            print(f"  ERROR: {exc}", file=sys.stderr, flush=True)

        main_rows.append(row)

    write_csv(
        Path(args.output),
        main_rows,
        [
            "core_file",
            "scenario",
            "run_id",
            "core_size_bytes",
            "strings_file",
            "status",
            "baseline_diff_file",
            "baseline_new_strings",
            "previous_diff_file",
            "previous_new_strings",
            "error",
        ],
    )
    write_csv(
        Path(args.marker_output),
        marker_rows,
        [
            "core_file",
            "scenario",
            "run_id",
            "marker_label",
            "marker_length_bytes",
            "exact_matches",
            "first_offset_hex",
        ],
    )
    write_csv(
        Path(args.db_search_output),
        db_rows,
        [
            "core_file",
            "scenario",
            "run_id",
            "db_value_label",
            "value_length_bytes",
            "value_sha256",
            "representation",
            "match_count",
            "first_offset_hex",
            "interpretation_note",
        ],
    )
    write_csv(
        Path(args.jwt_output),
        jwt_rows,
        ["core_file", "scenario", "run_id", "jwt_like_count", "jwt_first_offset_hex"],
    )

    print("\nWrote:")
    print(f"  {args.output}")
    print(f"  {args.marker_output}")
    print(f"  {args.db_search_output}")
    print(f"  {args.jwt_output}")
    print(f"Strings: {strings_dir}/")
    print(f"Diffs:   {diff_dir}/")


if __name__ == "__main__":
    main()

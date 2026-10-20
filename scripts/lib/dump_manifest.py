#!/usr/bin/env python3
"""
Atlas dump manifest and restore verification.

A pg_dump in plain format stores table data as COPY blocks:

    COPY public.users (id, email) FROM stdin;
    1\talice@example.com
    2\tbob@example.com
    \\.

Each data row is exactly one line (newlines inside values are escaped as \\n),
so counting lines between the COPY header and the "\\." terminator gives the
exact row count of every table *as captured in this backup*. That is the
number a restore must reproduce, independent of writes to the live database.

Commands:
  manifest  <dump.sql.gz>                      print manifest JSON
  count-sql <manifest.json>                    print a SQL query that counts every table
  summary   <manifest.json|result.json>         print a one-line human summary
  compare   <manifest.json> <counts.tsv>       compare restored counts (index<TAB>count), print result JSON
"""

import gzip
import json
import re
import sys
import time

MANIFEST_FORMAT = 1

# COPY [ONLY] schema.table [(columns)] FROM stdin;
COPY_RE = re.compile(r'^COPY\s+(?:ONLY\s+)?(?P<name>(?:"(?:[^"]|"")+"|[^\s(]+)(?:\.(?:"(?:[^"]|"")+"|[^\s(]+))?)\s*(?:\(.*\))?\s+FROM\s+stdin;\s*$')


def split_qualified(name):
    """Split 'schema.table' respecting double-quoted identifiers; returns (schema, table) unquoted."""
    parts, buf, in_quotes, i = [], [], False, 0
    while i < len(name):
        ch = name[i]
        if ch == '"':
            if in_quotes and i + 1 < len(name) and name[i + 1] == '"':
                buf.append('"')
                i += 2
                continue
            in_quotes = not in_quotes
        elif ch == "." and not in_quotes:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    parts.append("".join(buf))
    if len(parts) == 1:
        return "public", parts[0]
    return parts[0], ".".join(parts[1:])


def build_manifest(path):
    tables = {}  # (schema, table) -> rows
    current = None
    rows = 0
    # Detect gzip by content, not name: backups are written to *.tmp files first.
    with open(path, "rb") as probe:
        is_gzip = probe.read(2) == b"\x1f\x8b"
    opener = gzip.open if is_gzip else open
    saw_create_table = False
    with opener(path, "rt", encoding="utf-8", errors="replace", newline="\n") as fh:
        for line in fh:
            if current is None:
                if line.startswith("CREATE TABLE "):
                    saw_create_table = True
                if line.startswith("COPY "):
                    m = COPY_RE.match(line.rstrip("\n"))
                    if m:
                        current = split_qualified(m.group("name"))
                        rows = 0
                continue
            if line == "\\.\n" or line == "\\.":
                tables[current] = tables.get(current, 0) + rows
                current = None
                continue
            rows += 1
    if current is not None:
        raise ValueError(f"dump ended inside the COPY block for {current[0]}.{current[1]}; the archive is truncated")
    if saw_create_table and not tables:
        # pg_dump always writes a COPY block per table, even an empty one.
        raise ValueError("dump defines tables but no table data was found; it is not a plain-format pg_dump or could not be read")
    return {
        "format": MANIFEST_FORMAT,
        "generated_at": int(time.time()),
        "table_count": len(tables),
        "total_rows": sum(tables.values()),
        # Schema and table are kept apart: either may contain dots or quotes.
        "tables": [
            {"schema": schema, "table": table, "rows": n}
            for (schema, table), n in sorted(tables.items())
        ],
    }


def quote_ident(name):
    return '"' + name.replace('"', '""') + '"'


def count_sql(manifest):
    """One query returning '<index><TAB><count>' for every table in the manifest, in manifest order."""
    selects = []
    for i, entry in enumerate(manifest["tables"]):
        selects.append(
            f"SELECT {i} AS i, count(*) AS n FROM {quote_ident(entry['schema'])}.{quote_ident(entry['table'])}"
        )
    if not selects:
        return "SELECT NULL WHERE false;"
    return "\nUNION ALL\n".join(selects) + ";"


def compare(manifest, counts_text):
    found = {}
    for line in counts_text.splitlines():
        if not line.strip():
            continue
        idx, _, value = line.partition("\t")
        found[int(idx)] = int(value)

    mismatches = []
    for i, entry in enumerate(manifest["tables"]):
        name = f"{entry['schema']}.{entry['table']}"
        actual = found.get(i)
        if actual is None:
            mismatches.append({"table": name, "expected": entry["rows"], "actual": None, "problem": "missing"})
        elif actual != entry["rows"]:
            mismatches.append({"table": name, "expected": entry["rows"], "actual": actual, "problem": "row count differs"})

    return {
        "passed": not mismatches,
        "tables_expected": manifest["table_count"],
        "tables_verified": manifest["table_count"] - len(mismatches),
        "rows_expected": manifest["total_rows"],
        "rows_found": sum(found.values()),
        "mismatches": mismatches[:50],
    }


def summary(doc):
    """'5 tables, 1,334 rows' for a manifest; adds the first mismatches for a failed comparison."""
    if "tables_verified" in doc:
        mismatches = doc.get("mismatches") or []
        if not mismatches:
            return f"{doc['tables_verified']} tables, {doc['rows_found']:,} rows"
        parts = [
            f"{m['table']} is missing" if m["actual"] is None
            else f"{m['table']} has {m['actual']:,} rows, expected {m['expected']:,}"
            for m in mismatches[:3]
        ]
        more = len(mismatches) - 3
        if more > 0:
            parts.append(f"{more} more table{'s' if more != 1 else ''} differ")
        return "; ".join(parts)
    return f"{doc['table_count']} tables, {doc['total_rows']:,} rows"


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[1]
    try:
        if cmd == "manifest" and len(argv) == 3:
            print(json.dumps(build_manifest(argv[2]), indent=2))
        elif cmd == "summary" and len(argv) == 3:
            with open(argv[2], encoding="utf-8") as fh:
                print(summary(json.load(fh)))
        elif cmd == "count-sql" and len(argv) == 3:
            with open(argv[2], encoding="utf-8") as fh:
                print(count_sql(json.load(fh)))
        elif cmd == "compare" and len(argv) == 4:
            with open(argv[2], encoding="utf-8") as fh:
                manifest = json.load(fh)
            with open(argv[3], encoding="utf-8") as fh:
                result = compare(manifest, fh.read())
            print(json.dumps(result, indent=2))
            return 0 if result["passed"] else 1
        else:
            sys.stderr.write(__doc__)
            return 2
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"dump_manifest: {exc}\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

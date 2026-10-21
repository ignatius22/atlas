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

A mysqldump / mariadb-dump stores rows as INSERT statements whose tuples are
counted with a quote-aware scanner; tables with no rows are taken from their
CREATE TABLE. Its "-- Dump completed" footer must be present, so a truncated
MySQL dump is rejected.

Commands:
  manifest  <dump.sql.gz>                      print manifest JSON
  count-sql <manifest.json>                    print a SQL query that counts every table (dialect from the manifest)
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


def _open_dump(path):
    # Detect gzip by content, not name: backups are written to *.tmp files first.
    with open(path, "rb") as probe:
        is_gzip = probe.read(2) == b"\x1f\x8b"
    opener = gzip.open if is_gzip else open
    return opener(path, "rt", encoding="utf-8", errors="replace", newline="\n")


def detect_engine(head_lines):
    for line in head_lines:
        if line.startswith("-- MySQL dump") or line.startswith("-- MariaDB dump"):
            return "mysql"
        if "PostgreSQL database dump" in line:
            return "postgres"
    return "postgres"


def build_manifest(path):
    with _open_dump(path) as fh:
        head = []
        for line in fh:
            head.append(line)
            if len(head) >= 10:
                break
        engine = detect_engine(head)

        def lines():
            yield from head
            yield from fh

        tables = _mysql_tables(lines()) if engine == "mysql" else _postgres_tables(lines())

    return {
        "format": MANIFEST_FORMAT,
        "engine": engine,
        "generated_at": int(time.time()),
        "table_count": len(tables),
        "total_rows": sum(tables.values()),
        # Schema and table are kept apart: either may contain dots or quotes.
        "tables": [
            {"schema": schema, "table": table, "rows": n}
            for (schema, table), n in sorted(tables.items())
        ],
    }


def _postgres_tables(lines):
    tables = {}  # (schema, table) -> rows
    current = None
    rows = 0
    saw_create_table = False
    for line in lines:
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
    return tables


MYSQL_CREATE_RE = re.compile(r"^CREATE TABLE `((?:[^`]|``)+)`")
MYSQL_INSERT_RE = re.compile(r"^INSERT INTO `((?:[^`]|``)+)`(?:\s*\([^)]*\))?\s+VALUES\b")
# Strings (with backslash escapes) are skipped as one token; only structure characters count.
MYSQL_TOKEN_RE = re.compile(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|[();]")


def _mysql_tables(lines):
    tables = {}
    in_insert = None
    depth = 0
    completed = False
    for line in lines:
        if in_insert is None:
            if line.startswith("-- Dump completed"):
                completed = True
                continue
            m = MYSQL_CREATE_RE.match(line)
            if m:
                tables.setdefault(("", m.group(1).replace("``", "`")), 0)
                continue
            m = MYSQL_INSERT_RE.match(line)
            if not m:
                continue
            in_insert = ("", m.group(1).replace("``", "`"))
            tables.setdefault(in_insert, 0)
            depth = 0
            line = line[m.end():]
        for tok in MYSQL_TOKEN_RE.finditer(line):
            t = tok.group(0)
            if t == "(":
                if depth == 0:
                    tables[in_insert] += 1
                depth += 1
            elif t == ")":
                depth -= 1
            elif t == ";" and depth == 0:
                in_insert = None
                break
    if in_insert is not None:
        raise ValueError(f"dump ended inside the INSERT for {in_insert[1]}; the archive is truncated")
    if not completed:
        raise ValueError("MySQL dump has no '-- Dump completed' footer; the archive is truncated")
    return tables


def quote_ident(name):
    return '"' + name.replace('"', '""') + '"'


def quote_mysql_ident(name):
    return "`" + name.replace("`", "``") + "`"


def count_sql(manifest):
    """One query returning '<index><TAB><count>' for every table in the manifest, in manifest order."""
    mysql = manifest.get("engine") == "mysql"
    selects = []
    for i, entry in enumerate(manifest["tables"]):
        if mysql:
            target = quote_mysql_ident(entry["table"])
        else:
            target = f"{quote_ident(entry['schema'])}.{quote_ident(entry['table'])}"
        selects.append(f"SELECT {i} AS i, count(*) AS n FROM {target}")
    if not selects:
        return "SELECT NULL WHERE false;" if not mysql else "SELECT NULL FROM DUAL WHERE false;"
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
        name = f"{entry['schema']}.{entry['table']}" if entry["schema"] else entry["table"]
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

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

A mongodump --archive stream (stored gzipped) is binary: a header, one
metadata document per collection, then per-collection segments of BSON
documents, each collection closed by a header with EOF: true. Documents are
counted per collection straight from the archive; a collection without its
EOF header means the dump was cut off, and the archive is rejected. Views have
no data and are not counted. The server's own databases (admin, config, local)
are restored but not counted, because a fresh server already has its own.

Commands:
  manifest  <dump.sql.gz>                      print manifest JSON
  count-sql <manifest.json>                    print a query that counts every table (SQL dialect, or mongosh JS for MongoDB)
  summary   <manifest.json|result.json>         print a one-line human summary
  compare   <manifest.json> <counts.tsv>       compare restored counts (index<TAB>count), print result JSON
"""

import gzip
import json
import re
import struct
import sys
import time

MANIFEST_FORMAT = 1
MONGO_MAGIC = b"\x6d\xe2\x99\x81"  # mongodump archive, little-endian 0x8199e26d
MONGO_SYSTEM_DBS = {"admin", "config", "local"}

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


def _is_mongo_archive(path):
    with open(path, "rb") as probe:
        is_gzip = probe.read(2) == b"\x1f\x8b"
    opener = gzip.open if is_gzip else open
    try:
        with opener(path, "rb") as fh:
            return fh.read(4) == MONGO_MAGIC
    except (OSError, EOFError):
        return False


class _Reader:
    """Sequential reader over a (gzipped) binary stream."""

    def __init__(self, fh):
        self.fh = fh

    def exact(self, n):
        data = self.fh.read(n)
        if len(data) != n:
            raise ValueError("archive ends in the middle of a document (truncated)")
        return data


def _bson_header(raw):
    """Decode the flat fields Atlas needs (strings, booleans, ints) from one BSON document."""
    out, q, end = {}, 4, len(raw) - 1
    while q < end:
        kind = raw[q]
        q += 1
        key_end = raw.index(b"\0", q)
        key = raw[q:key_end].decode("utf-8", "replace")
        q = key_end + 1
        if kind == 0x02:  # string
            n = struct.unpack_from("<i", raw, q)[0]
            out[key] = raw[q + 4:q + 3 + n].decode("utf-8", "replace")
            q += 4 + n
        elif kind == 0x08:  # boolean
            out[key] = raw[q] == 1
            q += 1
        elif kind == 0x10:  # int32
            out[key] = struct.unpack_from("<i", raw, q)[0]
            q += 4
        elif kind in (0x12, 0x09, 0x11):  # int64, datetime, timestamp
            out[key] = struct.unpack_from("<q", raw, q)[0]
            q += 8
        elif kind == 0x01:  # double
            q += 8
        elif kind in (0x03, 0x04):  # document, array: skip
            q += struct.unpack_from("<i", raw, q)[0]
        else:
            break  # header documents only use the types above
    return out


def _mongo_collections(path):
    """{(db, collection): documents} for every data collection in a mongodump archive."""
    with open(path, "rb") as probe:
        is_gzip = probe.read(2) == b"\x1f\x8b"
    opener = gzip.open if is_gzip else open
    with opener(path, "rb") as fh:
        r = _Reader(fh)
        if r.exact(4) != MONGO_MAGIC:
            raise ValueError("not a mongodump archive")

        def next_doc():
            size_raw = r.exact(4)
            size = struct.unpack("<i", size_raw)[0]
            if size == -1:
                return None  # segment terminator
            if size < 5:
                raise ValueError("corrupt archive: invalid document size")
            return size_raw + r.exact(size - 4)

        prelude = next_doc()
        if prelude is None or "server_version" not in _bson_header(prelude) and "version" not in _bson_header(prelude):
            raise ValueError("corrupt archive: missing header")

        expected = {}  # namespace -> type
        while True:
            doc = next_doc()
            if doc is None:
                break
            meta = _bson_header(doc)
            if "db" in meta and "collection" in meta:
                expected[(meta["db"], meta["collection"])] = meta.get("type") or "collection"

        counts = {ns: 0 for ns in expected}
        finished = set()
        while True:
            size_raw = fh.read(4)
            if not size_raw:
                break  # clean end of archive
            if len(size_raw) != 4:
                raise ValueError("archive ends in the middle of a document (truncated)")
            size = struct.unpack("<i", size_raw)[0]
            if size == -1:
                continue
            header = _bson_header(size_raw + r.exact(size - 4))
            ns = (header.get("db"), header.get("collection"))
            if header.get("EOF"):
                finished.add(ns)
                terminator = fh.read(4)
                if terminator and terminator != b"\xff\xff\xff\xff":
                    raise ValueError("corrupt archive: missing segment terminator")
                continue
            while True:
                doc = next_doc()
                if doc is None:
                    break
                counts[ns] = counts.get(ns, 0) + 1

    unfinished = sorted(f"{db}.{coll}" for (db, coll) in expected if (db, coll) not in finished)
    if unfinished:
        raise ValueError(f"archive is truncated: {', '.join(unfinished[:3])} not complete")
    return {
        ns: n for ns, n in counts.items()
        if expected.get(ns) != "view" and ns[0] not in MONGO_SYSTEM_DBS
    }


def build_manifest(path):
    if _is_mongo_archive(path):
        collections = _mongo_collections(path)
        return {
            "format": MANIFEST_FORMAT,
            "engine": "mongodb",
            "generated_at": int(time.time()),
            "table_count": len(collections),
            "total_rows": sum(collections.values()),
            "tables": [
                {"schema": db, "table": coll, "rows": n}
                for (db, coll), n in sorted(collections.items())
            ],
        }
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


def count_mongo_js(manifest):
    """mongosh script printing '<index><TAB><count>' per collection; nothing for a missing one."""
    targets = json.dumps([[e["schema"], e["table"]] for e in manifest["tables"]])
    return (
        f"const targets = {targets};\n"
        "targets.forEach(([d, c], i) => {\n"
        "  const sib = db.getSiblingDB(d);\n"
        "  if (sib.getCollectionInfos({ name: c }).length === 0) return;\n"
        "  print(i + '\\t' + sib.getCollection(c).countDocuments({}));\n"
        "});\n"
    )


def count_sql(manifest):
    """One query returning '<index><TAB><count>' for every table in the manifest, in manifest order."""
    if manifest.get("engine") == "mongodb":
        return count_mongo_js(manifest)
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
        "engine": manifest.get("engine", "postgres"),
        "tables_expected": manifest["table_count"],
        "tables_verified": manifest["table_count"] - len(mismatches),
        "rows_expected": manifest["total_rows"],
        "rows_found": sum(found.values()),
        "mismatches": mismatches[:50],
    }


def summary(doc):
    """'5 tables, 1,334 rows' for a manifest; adds the first mismatches for a failed comparison."""
    table, row = ("collection", "document") if doc.get("engine") == "mongodb" else ("table", "row")

    def n(count, word):
        return f"{count:,} {word}{'' if count == 1 else 's'}"

    if "tables_verified" in doc:
        mismatches = doc.get("mismatches") or []
        if not mismatches:
            return f"{n(doc['tables_verified'], table)}, {n(doc['rows_found'], row)}"
        parts = [
            f"{m['table']} is missing" if m["actual"] is None
            else f"{m['table']} has {m['actual']:,} {row}s, expected {m['expected']:,}"
            for m in mismatches[:3]
        ]
        more = len(mismatches) - 3
        if more > 0:
            parts.append(f"{more} more {table}{'s' if more != 1 else ''} differ")
        return "; ".join(parts)
    return f"{n(doc['table_count'], table)}, {n(doc['total_rows'], row)}"


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
    except (OSError, EOFError, ValueError, KeyError, struct.error, json.JSONDecodeError) as exc:
        sys.stderr.write(f"dump_manifest: {exc}\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

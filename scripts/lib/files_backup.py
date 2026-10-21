#!/usr/bin/env python3
"""
Atlas file and volume backups.

Archives an app's Docker named volumes and host directories into one
.tar.gz and writes a manifest describing exactly what went in:

  {
    "format": 1,
    "sources": [{"kind": "volume", "name": "uploads", "prefix": "volumes/uploads", "files": 120, "bytes": 52011}, ...],
    "files": 1204, "bytes": 3400000,
    "digest": "<sha256 over every regular file's path, size and sha256>",
    "skipped": ["paths/var_www_app/tmp/sock (socket)", ...]
  }

The digest lets a restore drill prove, by reading the archive end to end,
that every file comes back byte for byte.

Commands:
  create  <archive.tar.gz> <manifest.json> [--volume NAME=MOUNTPOINT]... [--path DIR]... [--exclude GLOB]...
  verify  <archive.tar.gz> <manifest.json>        print result JSON, exit 1 on mismatch
  restore <archive.tar.gz> <target-dir>           safe extract (no absolute paths, no ..)
  summary <manifest.json|result.json>
"""

import fnmatch
import hashlib
import json
import os
import re
import stat
import sys
import tarfile
import tempfile
import time

FORMAT = 1
SPOOL_MAX = 64 * 1024 * 1024  # files up to 64 MB are staged in memory, larger ones on disk
CHUNK = 1024 * 1024


def safe_label(path):
    """Turn /var/www/app/storage into var_www_app_storage for use inside the archive."""
    label = re.sub(r"[^A-Za-z0-9._-]+", "_", path.strip("/")) or "root"
    return label


def _excluded(rel, excludes):
    return any(fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(os.path.basename(rel), pat) for pat in excludes)


def _record(digest_lines, arcname, size, sha):
    digest_lines.append(f"{arcname}\0{size}\0{sha}")


def _add_source(tar, root, prefix, excludes, digest_lines, skipped):
    """Add one directory tree. Returns (files, bytes). Never follows symlinks."""
    files = 0
    total = 0
    root = os.path.abspath(root)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir
        # Prune excluded directories
        dirnames[:] = [d for d in dirnames if not _excluded(os.path.join(rel_dir, d), excludes)]

        arc_dir = f"{prefix}/{rel_dir}".rstrip("/") if rel_dir else prefix
        info = tar.gettarinfo(dirpath, arcname=arc_dir)
        tar.addfile(info)

        for name in sorted(filenames):
            rel = os.path.join(rel_dir, name) if rel_dir else name
            if _excluded(rel, excludes):
                continue
            full = os.path.join(dirpath, name)
            arcname = f"{prefix}/{rel}"
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                skipped.append(f"{arcname} (deleted during backup)")
                continue

            if stat.S_ISLNK(st.st_mode):
                tar.addfile(tar.gettarinfo(full, arcname=arcname))
                continue
            if not stat.S_ISREG(st.st_mode):
                skipped.append(f"{arcname} (not a regular file)")
                continue

            # Stage the file first so a file that changes while being read can
            # never produce a tar entry whose size does not match its content.
            sha = hashlib.sha256()
            size = 0
            try:
                with open(full, "rb") as src, tempfile.SpooledTemporaryFile(max_size=SPOOL_MAX) as spool:
                    while True:
                        chunk = src.read(CHUNK)
                        if not chunk:
                            break
                        sha.update(chunk)
                        spool.write(chunk)
                        size += len(chunk)
                    spool.seek(0)
                    info = tarfile.TarInfo(arcname)
                    info.size = size
                    info.mode = stat.S_IMODE(st.st_mode)
                    info.uid, info.gid = st.st_uid, st.st_gid
                    info.mtime = int(st.st_mtime)
                    tar.addfile(info, spool)
            except (FileNotFoundError, PermissionError) as exc:
                skipped.append(f"{arcname} ({exc.__class__.__name__})")
                continue

            digest = sha.hexdigest()
            _record(digest_lines, arcname, size, digest)
            files += 1
            total += size
    return files, total


def create(archive, manifest_path, volumes, paths, excludes):
    sources = []
    digest_lines = []
    skipped = []
    tmp_archive = f"{archive}.tmp.{os.getpid()}"
    try:
        with tarfile.open(tmp_archive, "w:gz", compresslevel=6) as tar:
            for name, mountpoint in volumes:
                if not os.path.isdir(mountpoint):
                    raise ValueError(f"volume '{name}' mountpoint {mountpoint} is not a directory")
                prefix = f"volumes/{name}"
                f, b = _add_source(tar, mountpoint, prefix, excludes, digest_lines, skipped)
                sources.append({"kind": "volume", "name": name, "prefix": prefix, "files": f, "bytes": b})
            for path in paths:
                if not os.path.isdir(path):
                    raise ValueError(f"path {path} is not a directory")
                prefix = f"paths/{safe_label(path)}"
                f, b = _add_source(tar, path, prefix, excludes, digest_lines, skipped)
                sources.append({"kind": "path", "name": os.path.abspath(path), "prefix": prefix, "files": f, "bytes": b})
    except BaseException:
        if os.path.exists(tmp_archive):
            os.remove(tmp_archive)
        raise

    manifest = {
        "format": FORMAT,
        "kind": "files",
        "generated_at": int(time.time()),
        "sources": sources,
        "files": sum(s["files"] for s in sources),
        "bytes": sum(s["bytes"] for s in sources),
        "digest": _digest(digest_lines),
        "skipped": skipped[:200],
        "skipped_count": len(skipped),
    }
    tmp_manifest = f"{manifest_path}.tmp.{os.getpid()}"
    with open(tmp_manifest, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    os.replace(tmp_archive, archive)
    os.replace(tmp_manifest, manifest_path)
    return manifest


def _digest(lines):
    h = hashlib.sha256()
    for line in sorted(lines):
        h.update(line.encode("utf-8", "surrogateescape"))
        h.update(b"\n")
    return h.hexdigest()


def verify(archive, manifest):
    """Read every file in the archive and compare against the manifest."""
    digest_lines = []
    files = 0
    total = 0
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            if not member.isfile():
                continue
            fh = tar.extractfile(member)
            sha = hashlib.sha256()
            size = 0
            while True:
                chunk = fh.read(CHUNK)
                if not chunk:
                    break
                sha.update(chunk)
                size += len(chunk)
            if size != member.size:
                raise ValueError(f"{member.name}: archive entry is truncated")
            _record(digest_lines, member.name, size, sha.hexdigest())
            files += 1
            total += size
    digest = _digest(digest_lines)
    problems = []
    if files != manifest["files"]:
        problems.append(f"{files:,} files in archive, expected {manifest['files']:,}")
    if total != manifest["bytes"]:
        problems.append(f"{total:,} bytes in archive, expected {manifest['bytes']:,}")
    if digest != manifest["digest"] and not problems:
        problems.append("file contents differ from what was backed up")
    return {
        "passed": not problems,
        "files_expected": manifest["files"],
        "files_found": files,
        "bytes_expected": manifest["bytes"],
        "bytes_found": total,
        "problems": problems,
    }


def restore(archive, target):
    """Extract safely into target (must not exist or be empty)."""
    target = os.path.abspath(target)
    os.makedirs(target, exist_ok=True)
    if os.listdir(target):
        raise ValueError(f"{target} is not empty; restore into a new directory")
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            dest = os.path.abspath(os.path.join(target, member.name))
            if not dest.startswith(target + os.sep):
                raise ValueError(f"unsafe path in archive: {member.name}")
            if member.isdev() or member.isfifo():
                continue
            if member.issym() or member.islnk():
                base = target if member.islnk() else os.path.dirname(dest)
                link = os.path.abspath(os.path.join(base, member.linkname))
                if os.path.isabs(member.linkname) or not link.startswith(target + os.sep):
                    # A link that escapes the restore directory is not extracted.
                    sys.stderr.write(f"files_backup: skipped link leaving the restore directory: {member.name}\n")
                    continue
            if hasattr(tarfile, "tar_filter"):
                tar.extract(member, target, set_attrs=True, filter="tar")
            else:
                tar.extract(member, target, set_attrs=True)
    return target


def summary(doc):
    if "files_found" in doc:
        if doc["passed"]:
            return f"{doc['files_found']:,} files, {_human(doc['bytes_found'])}"
        return "; ".join(doc["problems"])
    return f"{doc['files']:,} files, {_human(doc['bytes'])} from {len(doc['sources'])} source{'s' if len(doc['sources']) != 1 else ''}"


def _human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n} B"


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    try:
        if cmd == "create" and len(args) >= 2:
            archive, manifest_path = args[0], args[1]
            volumes, paths, excludes = [], [], []
            rest = args[2:]
            i = 0
            while i < len(rest):
                flag = rest[i]
                if i + 1 >= len(rest):
                    raise ValueError(f"{flag} needs a value")
                value = rest[i + 1]
                if flag == "--volume":
                    name, _, mount = value.partition("=")
                    volumes.append((name, mount))
                elif flag == "--path":
                    paths.append(value)
                elif flag == "--exclude":
                    excludes.append(value)
                else:
                    raise ValueError(f"unknown option {flag}")
                i += 2
            if not volumes and not paths:
                raise ValueError("nothing to back up: give at least one --volume or --path")
            m = create(archive, manifest_path, volumes, paths, excludes)
            print(summary(m))
        elif cmd == "verify" and len(args) == 2:
            with open(args[1], encoding="utf-8") as fh:
                result = verify(args[0], json.load(fh))
            print(json.dumps(result, indent=2))
            return 0 if result["passed"] else 1
        elif cmd == "restore" and len(args) == 2:
            print(restore(args[0], args[1]))
        elif cmd == "summary" and len(args) == 1:
            with open(args[0], encoding="utf-8") as fh:
                print(summary(json.load(fh)))
        else:
            sys.stderr.write(__doc__)
            return 2
    except (OSError, ValueError, KeyError, tarfile.TarError, json.JSONDecodeError, EOFError) as exc:
        sys.stderr.write(f"files_backup: {exc}\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

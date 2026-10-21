#!/usr/bin/env python3
"""
atlas discover: propose apps.yml entries from the containers running on this host.

Groups containers by Docker Compose project (Coolify and Dokploy deploy with
Compose too). For each project it proposes:
  database   the PostgreSQL / MySQL / MariaDB container, with database name and
             user read from its environment (passwords are never read or printed)
  files      named volumes and host folders mounted by the project's other
             containers (user uploads, storage), excluding the database's own
             data volume, which the database dump already covers

Usage:
  discover.py [--config apps.yml] [--json] [--write]

--write appends the new apps to the config file after saving a copy as
<config>.bak-<timestamp>. Apps already present in the config are never changed.
"""

import datetime
import json
import os
import re
import shutil
import subprocess
import sys

ENGINE_PATTERNS = [
    ("mariadb", re.compile(r"(^|/)mariadb(:|$)|mariadb")),
    ("mysql", re.compile(r"(^|/)(mysql|percona)(-server)?(:|$)|mysql")),
    ("postgres", re.compile(r"postgres|postgis|timescaledb|pgvector|(^|/)supabase/postgres")),
]
DB_DATA_PATHS = ("/var/lib/postgresql", "/var/lib/mysql", "/bitnami/postgresql", "/bitnami/mysql", "/bitnami/mariadb")
SKIP_BIND_PREFIXES = ("/var/run", "/run", "/etc", "/proc", "/sys", "/dev", "/tmp", "/usr", "/lib", "/bin", "/sbin")
NOISE_VOLUME = re.compile(
    r"(^|[_-])(cache|tmp|temp|logs?|node_modules|letsencrypt|certbot|certs?)([_-]|$)"
    # Queues and caches rebuild themselves and their files change while running:
    # redis_data, redisdata, valkey-data, rabbitmq ...
    r"|redis|valkey|keydb|rabbitmq|memcache",
    re.I,
)
# Host folders that are regenerated, not app data (ACME challenge webroots, certificates).
NOISE_PATH = re.compile(r"(^|/)(certbot|letsencrypt|acme(-challenge)?)(/|$)", re.I)


def docker(*args):
    out = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"docker {' '.join(args)} failed")
    return out.stdout


def running_containers():
    ids = docker("ps", "-q").split()
    if not ids:
        return []
    return json.loads(docker("inspect", *ids))


def env_map(container):
    env = {}
    for item in (container.get("Config") or {}).get("Env") or []:
        key, _, value = item.partition("=")
        env[key] = value
    return env


def engine_of(image):
    image = image.lower()
    for engine, pattern in ENGINE_PATTERNS:
        if pattern.search(image):
            return engine
    return None


def db_server_score(c):
    score = 0
    if any((m.get("Destination") or "").startswith(DB_DATA_PATHS) for m in c.get("Mounts") or []):
        score += 2
    if any(k.startswith(("POSTGRES_", "MYSQL_", "MARIADB_")) for k in env_map(c)):
        score += 1
    return score


def slug(name):
    s = re.sub(r"[^a-z0-9_-]+", "-", name.lower()).strip("-_")
    if not s or not s[0].isalnum():
        s = "app-" + s
    return s[:48]


def project_of(c):
    labels = (c.get("Config") or {}).get("Labels") or {}
    return (
        labels.get("com.docker.compose.project")
        or labels.get("coolify.projectName")
        or labels.get("com.docker.stack.namespace")
        or c.get("Name", "").lstrip("/")
    )


def propose(containers):
    projects = {}
    for c in containers:
        projects.setdefault(project_of(c), []).append(c)

    apps = {}
    for project, members in sorted(projects.items()):
        # The database is the container running a database image; when several
        # share one (a migration job, a tool image), prefer the one that owns the
        # data directory or was configured as a server.
        db = None
        candidates = [(c, engine_of((c.get("Config") or {}).get("Image", ""))) for c in members]
        candidates = [(c, e) for c, e in candidates if e]
        if candidates:
            db = max(candidates, key=lambda ce: db_server_score(ce[0]))

        volumes, paths = [], []
        for c in members:
            if db and c is db[0]:
                continue
            if engine_of((c.get("Config") or {}).get("Image", "")):
                continue
            for m in c.get("Mounts") or []:
                dest = m.get("Destination", "")
                if dest.startswith(DB_DATA_PATHS):
                    continue
                if m.get("Type") == "volume":
                    name = m.get("Name", "")
                    # Anonymous volumes have 64-hex names; they are not app data you name and keep.
                    if re.fullmatch(r"[0-9a-f]{64}", name) or NOISE_VOLUME.search(name):
                        continue
                    if name not in volumes:
                        volumes.append(name)
                elif m.get("Type") == "bind":
                    src = m.get("Source", "")
                    if not src.startswith("/") or src.startswith(SKIP_BIND_PREFIXES) or "docker.sock" in src or NOISE_PATH.search(src):
                        continue
                    if not os.path.isdir(src) or src in paths:
                        continue
                    paths.append(src)

        if not db and not volumes and not paths:
            continue

        app = {"name": project, "directory": ""}
        workdir = ((members[0].get("Config") or {}).get("Labels") or {}).get("com.docker.compose.project.working_dir")
        if workdir:
            app["directory"] = workdir
        if db:
            c, engine = db
            env = env_map(c)
            entry = {"type": engine, "container": c.get("Name", "").lstrip("/"), "backup": True}
            if engine == "postgres":
                user = env.get("POSTGRES_USER") or "postgres"
                entry["user"] = user
                entry["name"] = env.get("POSTGRES_DB") or user
            else:
                name = env.get("MARIADB_DATABASE") or env.get("MYSQL_DATABASE")
                user = env.get("MARIADB_USER") or env.get("MYSQL_USER")
                if name:
                    entry["name"] = name
                if user and name:
                    entry["user"] = user
                else:
                    entry["user"] = "root"
            app["database"] = entry
        if volumes or paths:
            files = {}
            if volumes:
                files["volumes"] = volumes
            if paths:
                files["paths"] = paths
            app["files"] = files
        apps[slug(project)] = app
    return apps


def to_yaml(apps):
    def q(v):
        return json.dumps(v)  # JSON strings are valid YAML scalars

    lines = []
    for key, app in apps.items():
        lines.append(f"  {key}:")
        lines.append(f"    name: {q(app['name'])}")
        if app.get("directory"):
            lines.append(f"    directory: {q(app['directory'])}")
        if "database" in app:
            d = app["database"]
            lines.append("    database:")
            for k in ("type", "container", "name", "user"):
                if k in d:
                    lines.append(f"      {k}: {q(d[k])}")
            lines.append("      backup: true")
        if "files" in app:
            lines.append("    files:")
            for k in ("volumes", "paths"):
                if k in app["files"]:
                    lines.append(f"      {k}:")
                    for v in app["files"][k]:
                        lines.append(f"        - {q(v)}")
    return "\n".join(lines) + "\n"


def insert_into_apps_block(text, snippet):
    """Insert snippet at the end of the top-level 'apps:' mapping, keeping comments and other keys intact."""
    lines = text.splitlines(keepends=True)
    start = next((i for i, l in enumerate(lines) if re.match(r"^apps:\s*(#.*)?$", l)), None)
    if start is None:
        return text.rstrip("\n") + "\napps:\n" + snippet
    end = start + 1
    last_content = start
    while end < len(lines):
        line = lines[end]
        if line.strip() and not line.startswith((" ", "\t", "#")):
            break  # next top-level key
        if line.strip() and not line.lstrip().startswith("#"):
            last_content = end
        end += 1
    insert_at = last_content + 1
    lines[insert_at:insert_at] = [snippet if snippet.endswith("\n") else snippet + "\n"]
    return "".join(lines)


def existing_apps(config):
    return set(load_config_apps(config))


def load_config_apps(config):
    if not config or not os.path.exists(config):
        return {}
    vendor = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor")
    if os.path.isdir(vendor):
        sys.path.append(vendor)
    import yaml  # noqa: E402

    with open(config, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    apps = data.get("apps") or {}
    return apps if isinstance(apps, dict) else {}


def main(argv):
    config, as_json, write = None, False, False
    args = argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--config" and i + 1 < len(args):
            config = args[i + 1]
            i += 2
        elif args[i] == "--json":
            as_json = True
            i += 1
        elif args[i] == "--write":
            write = True
            i += 1
        else:
            sys.stderr.write(__doc__)
            return 2

    try:
        proposed = propose(running_containers())
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        sys.stderr.write(f"discover: cannot read containers: {exc}\n")
        return 1

    config_apps = load_config_apps(config)
    known = set(config_apps)
    new = {k: v for k, v in proposed.items() if k not in known}
    # Configured apps with discovered volumes/folders but no files section yet.
    files_hints = {
        k: v["files"] for k, v in proposed.items()
        if k in known and "files" in v and not (isinstance(config_apps.get(k), dict) and config_apps[k].get("files"))
    }

    if as_json:
        print(json.dumps({"new": new, "already_configured": sorted(set(proposed) & known), "files_hints": files_hints}, indent=2))
        return 0

    if not proposed:
        print("# No database containers or app volumes found among running containers.")
        return 0
    for name in sorted(set(proposed) & known):
        if name in files_hints:
            print(f"# {name}: already configured, but its files are not backed up. Add under apps.{name}:")
            hint = {name: {"name": name, "files": files_hints[name]}}
            body = to_yaml(hint).splitlines()
            print("\n".join(line for line in body if line.strip().startswith(("files:", "volumes:", "paths:", "- "))))
        else:
            print(f"# {name}: already in {config}, left unchanged")
    if not new:
        print("# Nothing new to add.")
        return 0

    snippet = to_yaml(new)
    if not write:
        print("# Proposed additions under 'apps:' in config/apps.yml. Review, then run with --write.")
        print(snippet, end="")
        return 0

    if not config:
        sys.stderr.write("discover: --write needs --config PATH\n")
        return 2
    if os.path.exists(config):
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        shutil.copy2(config, f"{config}.bak-{stamp}")
        with open(config, encoding="utf-8") as fh:
            text = fh.read()
        text = insert_into_apps_block(text, snippet)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(config)), exist_ok=True)
        text = 'version: "1.0"\napps:\n' + snippet
    tmp = f"{config}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, config)
    print(f"# Added {len(new)} app(s) to {config}: {', '.join(sorted(new))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

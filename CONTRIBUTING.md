# Contributing

Thanks for helping. Bug reports with the failing command and its output are as useful as code.

## Running the tests

You need Linux, Docker, Python 3, `age` and `rclone`. The end-to-end suites start real PostgreSQL, MySQL, MariaDB and MongoDB containers and write to `/var/backups`, so run them on a machine or VM you don't mind that on.

```bash
./tests/run-all.sh          # everything (or: make test)
bash tests/test-drill.sh    # one suite
```

Suites skip themselves, with a message, when Docker is not available. CI runs everything against PostgreSQL 14, 15 and 16.

## The dashboard

The React app lives in `dashboard/web`; its build in `dashboard/dist` is committed so servers never need Node.js. After changing the app:

```bash
cd dashboard/web
npm ci
npm test            # vitest
npm run build       # updates ../dist; commit it with your change
```

CI fails if `dashboard/dist` is out of date.

## Guidelines

- **Keep it boring.** Bash, the Python standard library (plus the vendored PyYAML) and the tools already on a VPS. No new runtime dependencies without discussion.
- **Never weaken a guarantee.** No local archive may be deleted before it is confirmed offsite; no private key may be written to the server; no password may reach a command line or a log. A change that touches these needs a test that would catch a regression.
- **Validate input where it is used.** App names, container names, paths and images are checked against strict patterns; arguments go through arrays, never `eval` or `shell=True`.
- **Test against the real thing.** New database or storage behaviour gets an end-to-end test with a real container, not only a mock.
- **Update the docs** in the same pull request when behaviour changes.

## Security issues

Report them privately, as described in [SECURITY.md](SECURITY.md), not in a public issue.

# Changelog

All notable changes to Atlas will be documented in this file.

## [Unreleased]
### Security
- `bin/atlas` no longer passes arguments through `eval`; app names containing shell syntax (for example `$(...)`) could previously execute commands.

### Changed
- CLI version is read from the new `VERSION` file (previously hardcoded as 1.0.0).
- Dashboard reads apps only from config and discovered backup directories; hardcoded app names and placeholder "healthy" containers are removed.
- Dashboard resolves the off-site provider from `ATLAS_S3_PROVIDER` or the endpoint instead of always reporting Cloudflare R2.
- Dashboard private-key scan is cached (default 10 minutes, `ATLAS_KEY_SCAN_TTL`) and skips files over 64 KB.
- `scripts/test-offsite-backup.sh` now requires an app name.

### Fixed
- `tests/test-systemd.sh` and `tests/test-notifications-dashboard.sh` are now executable, so `make test` passes locally.

## [1.0.0] - 2026-08-29
### Added
- Unified `atlas` CLI supporting `init`, `doctor`, `backup`, `restore`, `crypto`, and `config`.
- Asymmetric Age encryption envelope for zero-trust off-site replication.
- Ephemeral PostgreSQL restore verification drill engine.
- Declarative `atlas.yml` schema parser with container name regex enforcement.
- Infrastructure Doctor with exposed port scanning and resource pressure diagnostics.
- Comprehensive CI test matrix supporting PostgreSQL 14, 15, and 16.

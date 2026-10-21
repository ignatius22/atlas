# Deploy helpers (optional)

Atlas's job is backups and proving they restore. The repository also carries the small deploy scripts we use on our own servers. They are optional, independent of the backup path, and assume one Docker Compose stack per app in a git checkout. If you deploy with Coolify, Dokploy or CI, you do not need them.

## Configuration

They read these fields from `config/apps.yml`:

```yaml
apps:
  example-api:
    directory: "/srv/example-api"          # the git checkout with the compose file
    compose_file: "docker-compose.yml"     # default docker-compose.yml
    services:
      web:
        container: "example_api_web"
        healthcheck: "http://127.0.0.1:4000/health"
    deployment:
      branch: "main"
      auto_pull: true
      pre_deploy_hook: "scripts/migrate.sh"     # optional, an executable in the app directory
      post_deploy_hook: ""
```

## Deploy

```bash
./scripts/deploy.sh --app=example-api [--branch=release] [--dry-run] [--skip-healthcheck]
```

In order, it:

1. checks out the configured branch and pulls it (if `auto_pull` is true);
2. validates the compose file with `docker compose config -q`;
3. runs the pre-deploy hook, if set;
4. runs `docker compose up -d --build --remove-orphans`;
5. probes each service's `healthcheck` URL, 5 attempts;
6. runs the post-deploy hook, if set.

It stops at the first failed step and does not roll back by itself. Containers are recreated in place, so expect a few seconds of downtime per deploy.

Take a backup before a deploy that runs migrations: `atlas backup create example-api`.

## Roll back

```bash
./scripts/rollback.sh --app=example-api                 # previous commit
./scripts/rollback.sh --app=example-api --target=v1.4.2  # a tag or commit
```

It checks out the target, validates the compose file and rebuilds. Code only: if the newer version migrated the database, restore the backup taken before the deploy ([RECOVERY.md](../RECOVERY.md#1-roll-back-a-database)).

## Health checks

```bash
./scripts/health-check.sh --app=example-api
./scripts/health-check.sh --all
```

Checks that each service's container is running and its `healthcheck` URL answers.

## TLS and nginx

```bash
./scripts/setup-ssl.sh -d example.com -m you@example.com     # Certbot, webroot /var/www/certbot
```

`infra/nginx/` has a base `nginx.conf`, snippets for TLS, security headers and proxying, and `templates/app.conf.template` for a site. Copy and edit them for your server; Atlas does not install them.

## Make targets

`make deploy APP=x`, `make rollback APP=x`, `make health`, `make ssl DOMAIN=x`, `make setup` (checks server dependencies). Run `make help` for the full list.

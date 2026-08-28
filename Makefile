# ==============================================================================
# Atlas Production Template — Makefile
# ==============================================================================
# Developer & Operator Convenience Shortcuts
# ==============================================================================

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help doctor test backup restore deploy rollback health ssl setup check

help: ## Display available Atlas commands
	@printf "\n\033[1m\033[36mAtlas Production Template — Command Index\033[0m\n\n"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[32m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\n"

doctor: ## Run the Atlas production doctor diagnostic tool
	@./bin/doctor

test: ## Run the full automated test suite
	@./tests/run-all.sh

backup: ## Back up an application database (usage: make backup APP=myapp)
	@if [ -z "$(APP)" ]; then echo "Error: APP parameter required. Example: make backup APP=example-app"; exit 2; fi
	@./scripts/backup.sh --app=$(APP)

backup-all: ## Back up all registered applications
	@./scripts/backup.sh --all

restore: ## Restore an application database into test container (usage: make restore APP=myapp FILE=/path/to/backup.sql.gz [TARGET=test|production])
	@if [ -z "$(APP)" ] || [ -z "$(FILE)" ]; then echo "Error: APP and FILE parameters required. Example: make restore APP=example-app FILE=/var/backups/example-app/backup.sql.gz"; exit 2; fi
	@./scripts/restore.sh --app=$(APP) --file=$(FILE) --target=$(if $(TARGET),$(TARGET),test)

deploy: ## Deploy an application (usage: make deploy APP=myapp [BRANCH=main])
	@if [ -z "$(APP)" ]; then echo "Error: APP parameter required. Example: make deploy APP=example-app"; exit 2; fi
	@./scripts/deploy.sh --app=$(APP) $(if $(BRANCH),--branch=$(BRANCH),)

rollback: ## Roll back an application (usage: make rollback APP=myapp [TARGET=HEAD~1])
	@if [ -z "$(APP)" ]; then echo "Error: APP parameter required. Example: make rollback APP=example-app"; exit 2; fi
	@./scripts/rollback.sh --app=$(APP) $(if $(TARGET),--target=$(TARGET),)

health: ## Probe application health endpoints (usage: make health [APP=myapp])
	@if [ -n "$(APP)" ]; then ./scripts/health-check.sh --app=$(APP); else ./scripts/health-check.sh --all; fi

ssl: ## Obtain or renew SSL certificate (usage: make ssl DOMAIN=example.com [EMAIL=admin@example.com])
	@if [ -z "$(DOMAIN)" ]; then echo "Error: DOMAIN parameter required. Example: make ssl DOMAIN=example.com"; exit 2; fi
	@./scripts/setup-ssl.sh --domain=$(DOMAIN) $(if $(EMAIL),--email=$(EMAIL),)

setup: ## Verify server dependencies and initialize standard directories
	@./scripts/setup-server.sh

check: test doctor ## Run both test suite and local doctor diagnostic

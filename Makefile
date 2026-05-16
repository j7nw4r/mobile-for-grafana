# Make targets for the local Grafana dev loop. The same `integration/`
# stack will host the Phase 2 integration test target — see
# docs/12-integration-testing.md.

INTEGRATION_DIR := integration
COMPOSE         := docker compose -f $(INTEGRATION_DIR)/docker-compose.yml
ENV_FILE        := $(INTEGRATION_DIR)/.integration-env

.PHONY: help integration-up integration-down integration-token integration-logs integration-restart

help:
	@echo "Local Grafana for development:"
	@echo "  make integration-up       # start Grafana, wait healthy, mint token"
	@echo "  make integration-token    # print the current token + URL"
	@echo "  make integration-logs     # tail Grafana logs"
	@echo "  make integration-restart  # down + up (fresh state, fresh token)"
	@echo "  make integration-down     # stop containers + remove token file"

integration-up:
	$(COMPOSE) up -d
	@$(INTEGRATION_DIR)/scripts/wait-for-healthy.sh
	@$(INTEGRATION_DIR)/scripts/bootstrap-token.sh

integration-down:
	$(COMPOSE) down
	@rm -f $(ENV_FILE)

integration-restart: integration-down integration-up

integration-token:
	@test -f $(ENV_FILE) || { echo "No $(ENV_FILE) — run 'make integration-up' first."; exit 1; }
	@cat $(ENV_FILE)

integration-logs:
	$(COMPOSE) logs -f grafana

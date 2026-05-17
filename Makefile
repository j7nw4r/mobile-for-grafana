# Make targets for the local Grafana dev loop. The same `integration/`
# stack will host the Phase 2 integration test target — see
# docs/12-integration-testing.md.

INTEGRATION_DIR := integration
COMPOSE         := docker compose -f $(INTEGRATION_DIR)/docker-compose.yml
ENV_FILE        := $(INTEGRATION_DIR)/.integration-env

# Simulator settings — overridable.
SIM_DEVICE     ?= iPhone 17
APP_BUNDLE_ID  := com.grafanaviewer.GrafanaViewer
APP_SCHEME     := GrafanaViewer
BUILD_DIR      := /tmp/GrafanaViewer-build
APP_PATH       := $(BUILD_DIR)/Build/Products/Debug-iphonesimulator/GrafanaViewer.app

.PHONY: help integration-up integration-down integration-token integration-logs integration-restart sim sim-build

help:
	@echo "Local Grafana for development:"
	@echo "  make integration-up       # start Grafana, wait healthy, mint token"
	@echo "  make integration-token    # print the current token + URL"
	@echo "  make integration-logs     # tail Grafana logs"
	@echo "  make integration-restart  # down + up (fresh state, fresh token)"
	@echo "  make integration-down     # stop containers + remove token file"
	@echo ""
	@echo "Simulator:"
	@echo "  make sim                  # build + boot + install + launch with prefilled login"
	@echo "  make sim-build            # build only (debug, simulator)"

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

sim-build:
	cd GrafanaViewer && xcodebuild \
	  -scheme $(APP_SCHEME) \
	  -destination 'platform=iOS Simulator,name=$(SIM_DEVICE)' \
	  -configuration Debug \
	  -derivedDataPath $(BUILD_DIR) \
	  -quiet build

# Build + install + launch the app with GRAFANA_URL/TOKEN piped into the
# app via SIMCTL_CHILD_* env vars. LoginView's #if DEBUG init reads
# those and prefills the form, so verification is one tap on Continue.
sim: sim-build
	@test -f $(ENV_FILE) || { echo "No $(ENV_FILE) — run 'make integration-up' first."; exit 1; }
	@DEVICE_ID=$$(xcrun simctl list devices available \
	  | awk '/-- iOS / {ver=$$3; next} /$(SIM_DEVICE) \(/ {print ver" "$$0}' \
	  | sort -V \
	  | tail -1 \
	  | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/'); \
	  if [ -z "$$DEVICE_ID" ]; then echo "No simulator named '$(SIM_DEVICE)' available"; exit 1; fi; \
	  echo "Device: $$DEVICE_ID ($(SIM_DEVICE))"; \
	  xcrun simctl boot "$$DEVICE_ID" 2>/dev/null || true; \
	  open -a Simulator; \
	  xcrun simctl install "$$DEVICE_ID" $(APP_PATH); \
	  set -a; . $(ENV_FILE); set +a; \
	  SIMCTL_CHILD_GRAFANA_URL="$$GRAFANA_URL" \
	  SIMCTL_CHILD_GRAFANA_TOKEN="$$GRAFANA_TOKEN" \
	    xcrun simctl launch --terminate-running-process "$$DEVICE_ID" $(APP_BUNDLE_ID)

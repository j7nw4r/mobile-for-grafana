#!/usr/bin/env bash
# Block until Grafana reports healthy via /api/health, up to a 90s budget.
# Cold-pulling the image is ~30s on a fresh machine; Grafana itself
# needs another ~10s to be ready to mint tokens.

set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
BUDGET_SECONDS="${HEALTH_BUDGET_SECONDS:-90}"
deadline=$(( $(date +%s) + BUDGET_SECONDS ))

printf "Waiting for Grafana at %s " "$GRAFANA_URL"
while true; do
  if curl --silent --fail --max-time 2 "$GRAFANA_URL/api/health" > /dev/null 2>&1; then
    printf " ready\n"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf "\nERROR: Grafana did not become healthy within %ss\n" "$BUDGET_SECONDS" >&2
    exit 1
  fi
  printf "."
  sleep 2
done

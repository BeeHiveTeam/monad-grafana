#!/usr/bin/env bash
# Helper installer — automates the Quick Start from README.md.
# Idempotent: safe to re-run.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Checking prerequisites…"
command -v docker >/dev/null || { echo "Error: docker not installed"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Error: docker compose plugin missing"; exit 1; }
command -v ufw >/dev/null || echo "Warning: ufw not installed — UFW step will be skipped"

echo "==> Generating Grafana admin password (only once)…"
if [[ ! -f .env ]]; then
  cp .env.example .env
  PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  sed -i "s|changeme-please-generate-strong-password|$PASS|" .env
  chmod 600 .env
  echo
  echo "    Grafana admin password: $PASS"
  echo "    (Saved to .env mode 0600. Write it down now.)"
  echo
else
  echo "    .env already exists — keeping current password."
fi

echo "==> Starting docker compose…"
docker compose up -d

echo "==> Waiting for Prometheus to come up (10s)…"
sleep 10

if command -v ufw >/dev/null; then
  SUBNET=$(docker network inspect "$(basename "$PWD")_monitoring" \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "")
  if [[ -n "$SUBNET" ]]; then
    echo "==> Adding UFW allow rules for docker subnet $SUBNET → :8889 and :8080…"
    sudo ufw allow from "$SUBNET" to any port 8889 proto tcp comment 'monitoring → otelcol' || true
    sudo ufw allow from "$SUBNET" to any port 8080 proto tcp comment 'monitoring → monad-rpc' || true
  else
    echo "Warning: couldn't detect docker subnet; add UFW rule manually (see README)."
  fi
fi

echo "==> Reloading Prometheus and waiting for first scrape (15s)…"
curl -sS -X POST http://127.0.0.1:9090/-/reload >/dev/null || true
sleep 15

echo "==> Verifying Prometheus targets:"
curl -s http://127.0.0.1:9090/api/v1/targets \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d['data']['activeTargets']:
    print(f\"    {t['labels'].get('job'):22s} {t['health']}\")"

echo
echo "==> Done. Open Grafana via SSH tunnel:"
echo "    ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 user@$(hostname -I | awk '{print $1}')"
echo "    then http://localhost:3000  (admin / see .env)"

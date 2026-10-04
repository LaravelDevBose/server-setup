#!/usr/bin/env bash
# Run on the PROD host after editing .env:  ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env  ->  cp .env.example .env  and edit it"; exit 1; }
set -a; . ./.env; set +a
for v in HOST_NAME INGEST_URL INGEST_USER INGEST_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "$v empty in .env"; exit 1; }
done
sed -e "s|@HOST_NAME@|$HOST_NAME|g" -e "s|@INGEST_URL@|${INGEST_URL%/}|g" -e "s|@INGEST_USER@|$INGEST_USER|g" \
  prometheus-agent.yml.tpl > prometheus-agent.yml
printf '%s' "$INGEST_PASSWORD" > ingest_password
chmod 600 ingest_password .env
docker compose up -d
sleep 10
docker compose ps
echo "--- recent errors (none = good) ---"
docker compose logs --tail=200 prometheus-agent promtail 2>&1 | grep -Ei 'error|401|403|denied|no such' | tail -20 || true

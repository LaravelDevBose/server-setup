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
profiles=()
add_job() { printf '  - job_name: %s\n    static_configs: [{targets: [%s]}]\n' "$1" "'$2'" >> prometheus-agent.yml; }
if [ -n "${REDIS_HOST:-}" ] || [ -n "${MYSQL_HOST:-}" ] || [ -n "${NGINX_HOST:-}" ]; then
  [ -n "${APP_NETWORK:-}" ] || { echo "APP_NETWORK required when *_HOST set"; exit 1; }
fi
if [ -n "${REDIS_HOST:-}" ]; then profiles+=(redis); add_job redis redis-exporter:9121; fi
if [ -n "${NGINX_HOST:-}" ]; then profiles+=(nginx); add_job nginx nginx-exporter:9113; fi
if [ -n "${MYSQL_HOST:-}" ]; then
  profiles+=(mysql); add_job mysql mysqld-exporter:9104
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "${MYSQL_EXPORTER_USER:-exporter}" "${MYSQL_EXPORTER_PASSWORD:-}" "$MYSQL_HOST" > mysqld.cnf
  chmod 644 mysqld.cnf  # exporter runs as nobody
fi
export COMPOSE_PROFILES=$(IFS=,; echo "${profiles[*]:-}")
chmod 600 ingest_password .env
docker compose up -d
sleep 10
docker compose ps
echo "--- recent errors (none = good) ---"
docker compose logs --tail=200 prometheus-agent promtail 2>&1 | grep -Ei 'error|401|403|denied|no such' | tail -20 || true

#!/usr/bin/env bash
# Run on the PROD host after editing .env:  ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "Missing .env  ->  cp .env.example .env  and edit it"; exit 1; }
set -a; . ./.env; set +a

# 1. Added MYSQL_EXPORTER_PASSWORD to required check if MYSQL_HOST is set
for v in HOST_NAME INGEST_URL INGEST_USER INGEST_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "$v empty in .env"; exit 1; }
done

if [ -n "${MYSQL_HOST:-}" ] && [ -z "${MYSQL_EXPORTER_PASSWORD:-}" ]; then
  echo "MYSQL_EXPORTER_PASSWORD is required in .env when MYSQL_HOST is set"; exit 1;
fi

# 2. Re-generate prometheus-agent.yml
sed -e "s|@HOST_NAME@|$HOST_NAME|g" \
    -e "s|@INGEST_URL@|${INGEST_URL%/}|g" \
    -e "s|@INGEST_USER@|$INGEST_USER|g" \
    prometheus-agent.yml.tpl > prometheus-agent.yml

profiles=()
add_job() { printf '  - job_name: %s\n    static_configs: [{targets: [%s]}]\n' "$1" "'$2'" >> prometheus-agent.yml; }

if [ -n "${REDIS_HOST:-}" ] || [ -n "${MYSQL_HOST:-}" ] || [ -n "${NGINX_HOST:-}" ] || [ -n "${TRAEFIK_HOST:-}" ]; then
  [ -n "${APP_NETWORK:-}" ] || { echo "APP_NETWORK required when *_HOST set"; exit 1; }
fi

if [ -n "${TRAEFIK_HOST:-}" ]; then add_job traefik "$TRAEFIK_HOST:8082"; fi
if [ -n "${REDIS_HOST:-}" ]; then profiles+=(redis); add_job redis redis-exporter:9121; fi
if [ -n "${NGINX_HOST:-}" ]; then profiles+=(nginx); add_job nginx nginx-exporter:9113; fi

if [ -n "${MYSQL_HOST:-}" ]; then
  profiles+=(mysql)
  add_job mysql mysqld-exporter:9104

  # Added double quotes around %s for password
  printf '[client]\nuser=%s\npassword="%s"\nhost=%s\n' \
    "${MYSQL_EXPORTER_USER:-exporter}" \
    "${MYSQL_EXPORTER_PASSWORD}" \
    "$MYSQL_HOST" > mysqld.cnf
  chmod 644 mysqld.cnf
fi

export COMPOSE_PROFILES=$(IFS=,; echo "${profiles[*]:-}")
chmod 600 ingest_password .env

# 3. Force container recreation so Docker binds to the new file inodes
docker compose up -d --force-recreate

# 4. Explicitly restart containers to reload newly generated config files
docker compose restart

sleep 5
docker compose ps

echo "--- recent errors (none = good) ---"
docker compose logs --tail=200 prometheus-agent promtail mysqld-exporter 2>&1 | grep -Ei 'error|401|403|denied|no such' | tail -20 || true
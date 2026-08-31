#!/usr/bin/env bash
# Idempotent first-run setup: env files, secrets, data directories, local TLS cert.
set -euo pipefail

cd "$(dirname "$0")/.."

rand() { openssl rand -hex "$1"; }

# sed -i differs between BSD (macOS) and GNU (Linux).
sedi() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }

for f in .env mailu.env; do
  if [[ ! -f "$f" ]]; then
    cp "$f.example" "$f"
    echo "created $f"
  else
    echo "$f already exists — left untouched"
  fi
done

# Mailu's web login validator rejects special-use TLDs, which silently locks the
# admin account out of the UI while SMTP and the API keep working.
for key in DOMAIN INITIAL_ADMIN_DOMAIN; do
  value=$(grep "^$key=" mailu.env | cut -d= -f2)
  case "$value" in
    *.test|*.local|*.internal|*.example|*.invalid|localhost)
      echo "ERROR: $key=$value uses a special-use TLD." >&2
      echo "       The admin account would be unable to log into the web UI." >&2
      echo "       Use a normal domain (e.g. example.com) in mailu.env." >&2
      exit 1
      ;;
  esac
done

# Replace placeholder secrets only once.
if grep -q '^SECRET_KEY=CHANGE_ME' mailu.env; then sedi "s|^SECRET_KEY=.*|SECRET_KEY=$(rand 8)|" mailu.env; echo "generated SECRET_KEY"; fi
if grep -q '^API_TOKEN=CHANGE_ME' mailu.env; then sedi "s|^API_TOKEN=.*|API_TOKEN=$(rand 32)|" mailu.env; echo "generated API_TOKEN"; fi
if grep -q '^RESTIC_PASSWORD=$' .env; then sedi "s|^RESTIC_PASSWORD=.*|RESTIC_PASSWORD=$(rand 24)|" .env; echo "generated RESTIC_PASSWORD"; fi

ROOT=$(grep '^MAILU_DATA_ROOT=' .env | cut -d= -f2)

mkdir -p \
  "$ROOT"/{mail,mailqueue,data,dkim,certs,redis,filter,webmail,dav,clamav,backups} \
  "$ROOT"/overrides/{nginx,dovecot,postfix,rspamd,roundcube}

chmod 700 "$ROOT"/certs "$ROOT"/dkim "$ROOT"/data
echo "data directories ready under $ROOT"

# Self-signed cert so TLS_FLAVOR=cert works out of the box. On the VPS this is
# overwritten by ops/certs/certbot-deploy-hook.sh with the real Let's Encrypt cert.
if [[ ! -f "$ROOT/certs/cert.pem" ]]; then
  HOST=$(grep '^HOSTNAMES=' mailu.env | cut -d= -f2 | cut -d, -f1)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$ROOT/certs/key.pem" -out "$ROOT/certs/cert.pem" \
    -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST" 2>/dev/null
  chmod 600 "$ROOT/certs/key.pem"
  echo "generated self-signed certificate for $HOST"
fi

echo
echo "Next: review .env and mailu.env, then run  docker compose up -d"

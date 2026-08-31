#!/usr/bin/env bash
# Thin wrapper around Mailu's CLI inside the admin container.
#   ./scripts/mailu.sh domain a.com
#   ./scripts/mailu.sh user info a.com 'password'
#   ./scripts/mailu.sh admin me a.com 'password'
#   ./scripts/mailu.sh config-export --secrets
set -euo pipefail
cd "$(dirname "$0")/.."
exec docker compose exec admin flask mailu "$@"

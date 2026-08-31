#!/usr/bin/env bash
# Print the exact DNS records to create for each hosted domain.
# Mailu generates these itself, so they always match the live DKIM key.
#
#   ./scripts/dns-records.sh              # all domains
#   ./scripts/dns-records.sh a.com        # one domain
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE_URL:-https://localhost:8443}"
TOKEN=$(grep '^API_TOKEN=' mailu.env | cut -d= -f2)

fetch() { curl -sk -H "Authorization: $TOKEN" "$BASE/api/v1$1"; }

domains=("$@")
if [[ ${#domains[@]} -eq 0 ]]; then
  mapfile -t domains < <(fetch /domain | python3 -c 'import sys,json;[print(d["name"]) for d in json.load(sys.stdin)]')
fi

for d in "${domains[@]}"; do
  echo "═══ $d ═══"
  fetch "/domain/$d" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for key in ("dns_mx", "dns_spf", "dns_dkim", "dns_dmarc"):
    if d.get(key):
        print(d[key])
for rec in d.get("dns_autoconfig", []):
    print(rec)
'
  echo
done

cat <<'EOF'
Namecheap: Domain List > Manage > Advanced DNS.
  MX    -> Host "@",              Mail Server = the target, Priority = the number
  TXT   -> Host "@" (SPF), "dkim._domainkey" (DKIM), "_dmarc" (DMARC)
  CNAME -> Host "autoconfig" / "autodiscover"
Strip the trailing dot and the "600 IN <TYPE>" part; Namecheap adds those itself.

Also required once, on the mail host's own domain:
  A    mail -> <VPS public IP>
  PTR  <VPS public IP> -> mail.<primary>.com   (set in your VPS provider's panel)
EOF

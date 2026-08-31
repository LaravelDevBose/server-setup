# Deploying to the VPS

The server already runs other websites behind nginx on ports 80/443. The mail
stack therefore publishes its web UI on loopback-only high ports and lets nginx
reverse-proxy to it. Mail protocol ports are bound directly and do not involve
nginx at all.

## 1. Preflight

Outbound port 25 must be open, and the mail hostname needs both a forward and a
reverse record. Reverse DNS is set in your VPS provider's control panel, not at
Namecheap, and mail from a host without it is widely rejected.

```bash
nc -zv gmail-smtp-in.l.google.com 25     # must connect
dig +short mail.example.com              # must return the VPS public IP
dig +short -x <VPS_PUBLIC_IP>            # must return mail.example.com
ss -lntp | grep -E ':(25|465|587|993|4190)\b'   # must be empty
```

Then check the host can actually carry the stack:

```bash
free -g                  # >= 2 GB free; add ~1.5 GB more if ANTIVIRUS=clamav
nproc                    # >= 2 vCPU
df -h /srv               # mail storage: (quota x users) x 1.3 for indexes and queue
docker --version         # engine 20.10+
docker compose version   # must be v2 — this stack uses `docker compose`, not docker-compose
```

Mailu without ClamAV settles around 1.5–2 GB. The 1.3 multiplier on mailbox
quota covers the Dovecot full-text index, Rspamd data and the Postfix queue.

## 2. Install the stack

```bash
git clone <this repo> /opt/mail-server && cd /opt/mail-server
./scripts/bootstrap.sh
```

Edit `.env` for production. The values differ from the local test defaults:

```ini
MAILU_DATA_ROOT=/srv/mailu
MAIL_HOSTNAME=mail.example.com
BIND_ADDRESS4=<VPS_PUBLIC_IP>
SMTP_PORT=25
SUBMISSIONS_PORT=465
SUBMISSION_PORT=587
IMAPS_PORT=993
SIEVE_PORT=4190
TZ=Asia/Dhaka
```

Then edit `mailu.env`:

```ini
DOMAIN=example.com
HOSTNAMES=mail.example.com
WEBSITE=https://mail.example.com
INITIAL_ADMIN_DOMAIN=example.com
INITIAL_ADMIN_PW=<strong password, change after first login>
REAL_IP_HEADER=X-Forwarded-For
REAL_IP_FROM=172.0.0.0/8             # must match the `proxy` Docker network CIDR
                                     # verify: docker network inspect proxy | grep Subnet
SESSION_COOKIE_SECURE=True
```

`REAL_IP_FROM` must be set whenever `REAL_IP_HEADER` is. Setting the header
alone lets a client forge its own source address and defeat rate limiting and
banning.

## 3. Certificate

Traefik automatically provisions and renews the TLS certificate for the web UI
(`mail.example.com`) via Let's Encrypt — no manual certbot step needed for that.

The mail protocol ports (25, 465, 587, 993) bypass Traefik entirely and are
terminated by Mailu's `front` container, which needs its own certificate.
`bootstrap.sh` generates a self-signed one for local testing. For production,
install certbot and a deploy hook that copies the renewed cert into the data dir:

```bash
certbot certonly --webroot -w /var/www/certbot -d mail.example.com

install -m 755 ops/certs/certbot-deploy-hook.sh \
  /etc/letsencrypt/renewal-hooks/deploy/mailu.sh
MAIL_HOST=mail.example.com STACK_DIR=/opt/mail-server CERT_DIR=/srv/mailu/certs \
  /etc/letsencrypt/renewal-hooks/deploy/mailu.sh
```

Edit the defaults at the top of the installed hook so renewals pick them up
automatically. Verify renewal works before relying on it:

```bash
certbot renew --dry-run
```

## 4. Traefik

Traefik (running separately under `traefik/`) handles HTTPS for the web UI.
Make sure Traefik is up and the `proxy` Docker network exists before starting
the mail stack:

```bash
cd ../traefik && docker compose up -d
docker network inspect proxy   # note the Subnet — set REAL_IP_FROM to it in mailu.env
cd ../mail-server
```

No nginx vhost is needed. Traefik discovers the `front` container automatically
via Docker labels and routes `mail.example.com` to it.

## 5. Start

```bash
docker compose up -d
docker compose ps        # every service should report healthy
```

## 6. Firewall

Only the mail protocols are public. The web UI is served by Traefik on the
standard 80/443 ports — no extra rules needed for it.

```bash
ufw allow 80/tcp && ufw allow 443/tcp    # Traefik (if not already open)
ufw allow 25/tcp && ufw allow 465/tcp && ufw allow 587/tcp
ufw allow 993/tcp && ufw allow 4190/tcp
```

## 7. Brute-force banning (fail2ban)

Mailu already rate-limits authentication in the application (`AUTH_RATELIMIT_IP`).
fail2ban adds a kernel-level block, so a repeat offender stops consuming TLS
handshakes and worker processes entirely.

Both jails read the `front` container's journal, so start the stack with the
journald overlay. It changes only that one container; everything else keeps the
size-capped `json-file` driver.

```bash
apt install fail2ban
docker compose -f docker-compose.yml -f ops/fail2ban/compose.journald.yml up -d

cp ops/fail2ban/filter.d/mailu-*.conf /etc/fail2ban/filter.d/
cp ops/fail2ban/jail.d/mailu.local  /etc/fail2ban/jail.d/
```

Edit `ignoreip` in the installed jail so it matches `SUBNET` from `.env`, then
validate the patterns against real traffic **before** enabling:

```bash
fail2ban-regex systemd-journal[CONTAINER_TAG=mailu-front] /etc/fail2ban/filter.d/mailu-auth.conf
fail2ban-regex systemd-journal[CONTAINER_TAG=mailu-front] /etc/fail2ban/filter.d/mailu-web.conf

systemctl reload fail2ban
fail2ban-client status mailu-auth
```

Confirm a ban actually happens, from another machine:

```bash
for i in $(seq 6); do
  swaks --server mail.example.com:587 --auth-user info@a.com --auth-password wrong
done
fail2ban-client status mailu-auth      # the IP should be listed
fail2ban-client set mailu-auth unbanip <IP>
```

Two failure modes worth knowing:

- **The web jail depends on `REAL_IP_HEADER` and `REAL_IP_FROM`.** Without them
  every `/sso/login` hit is logged with the host nginx bridge address, so the
  jail bans your own reverse proxy and takes the web UI down for everyone. The
  shipped `ignoreip` covers the Mailu subnet to blunt this, but the real fix is
  configuring both variables as in section 2.
- `banaction = nftables-multiport` assumes nftables. On an iptables host use
  `iptables-multiport` instead.

## 8. Domains and DNS

Add each domain in the panel, generate its DKIM keys, then:

```bash
BASE_URL=https://mail.example.com ./scripts/dns-records.sh
```

Paste the output into Namecheap's Advanced DNS for each domain. All domains
point their MX at the single `mail.example.com` host.

## 9. Verify

```bash
MAIL_HOST=mail.example.com SUBMISSION_PORT=587 SUBMISSIONS_PORT=465 \
  SENDER=info@a.com PASSWORD=... RCPT=abc@b.com VERIFY_TLS=1 \
  python3 scripts/smoke-test.py
```

Send a message to <https://www.mail-tester.com> and aim for 10/10, then confirm
inbound delivery from an external account and check the received headers show
`spf=pass`, `dkim=pass` and `dmarc=pass`.

### Open-relay test — must run from another machine

Postfix trusts `mynetworks`, which is `127.0.0.1/32` plus the Mailu docker
subnet. Docker's userland proxy rewrites the source address of loopback
connections to the bridge gateway, which falls inside that subnet, so a relay
test run *on the VPS* always appears to succeed and proves nothing. Run it from
a different host:

```bash
swaks --server mail.example.com:25 \
      --from attacker@evil.example --to victim@gmail.com
# expected: 554 5.7.1 Relay access denied
```

A consequence worth knowing: anything that can open a local connection on the
VPS itself, including your other websites and containers, can relay through
port 25 without authentication. Keep `RELAYNETS` empty and give backend apps
their own authenticated accounts instead.

## Upgrading

```bash
# read the release notes first: https://mailu.io/master/releases.html
sed -i 's/^MAILU_VERSION=.*/MAILU_VERSION=<new>/' .env
docker compose pull && docker compose up -d
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `resolver` restart-loops with `unbound.conf:11: error` | `SUBNET` not reaching the container; it is injected from `.env` via compose |
| Backend app cannot connect on 587 | `587` missing from `PORTS` in `mailu.env` — Mailu's default omits it |
| "Invalid email address" at login | Special-use TLD (`.test`, `.local`); Mailu's validator rejects them |
| Rate limits ban the wrong client | `REAL_IP_HEADER` set without a correct `REAL_IP_FROM` |
| Odd errors everywhere after setup | No mailbox or alias matching `POSTMASTER` |
| Attachments fail to upload | Traefik has no body limit by default; check `MESSAGE_SIZE_LIMIT` in `mailu.env` |

```bash
docker compose logs -f smtp    # delivery problems
docker compose logs -f front   # TLS, proxying, auth
docker compose exec smtp postqueue -p    # stuck outbound mail
```

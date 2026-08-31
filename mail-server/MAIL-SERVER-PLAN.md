# Plan: Multi-Domain Dockerized Mail Server (Mailu)

Build a self-hosted, multi-domain mail server on the VPS using **Mailu** (Postfix + Dovecot +
Rspamd + Roundcube + admin panel) orchestrated with Docker Compose. All state lives on host
bind-mounts so mail survives container/stack restarts. Existing host **nginx** stays the public
edge on 80/443; Mailu's web UI is published on loopback-only custom ports and reverse-proxied.
Mail protocol ports (25/465/587/993/4190) are bound directly. Everything toggleable through
two env files.

Workspace: `/Users/bs01012/Work/Myworks/server` (currently empty — greenfield).

---

## Confirmed context (from user)

| Item | Value |
|---|---|
| Stack | Mailu |
| VPS | >8 GB RAM, port 25 **open**, shared with other websites |
| Edge | Existing **nginx** on 80/443 → Mailu web on custom loopback ports |
| Domains | Multiple independent domains (a.com, b.com, …), MX managed at **Namecheap** |
| Optional components | Webmail (Roundcube), Rspamd + DKIM, fail2ban/brute-force, encrypted backups, API for programmatic mailbox creation |
| Excluded | ClamAV antivirus (not selected — kept behind a disabled compose profile) |

**Resource answer:** Mailu without ClamAV ≈ 1.5–2 GB RAM steady state, 2 vCPU, plus mail
storage. With ClamAV add ~1.5 GB. 8 GB VPS is comfortable. Budget disk = (mailbox quota ×
users) × 1.3 for Dovecot FTS index + Rspamd data + mail queue.

---

## Architecture

```
Internet
  │
  ├─ 25 / 465 / 587 / 993 / 4190  ──────────────► mailu-front (published on 0.0.0.0)
  │
  └─ 80 / 443 ──► host nginx (existing)
                    ├─ other websites …
                    └─ mail.<primary>.com ──► 127.0.0.1:${FRONT_HTTP_PORT} (mailu-front)
                                                 ├─ /admin   → admin panel (global admin only)
                                                 ├─ /webmail → Roundcube (end users)
                                                 └─ /api     → RESTful API (token auth)
```

Mailu internal services on a dedicated bridge network `${SUBNET}`:
`resolver (unbound)`, `redis`, `front (nginx)`, `admin`, `imap (dovecot)`, `smtp (postfix)`,
`oletools`, `antispam (rspamd)`, `webmail (roundcube)`, optional `webdav`, `fetchmail`,
`antivirus`, plus our own `backup` sidecar.

**Why users can't see the domain list:** in Mailu the domain list is rendered only for accounts
flagged *Global Admin*. A normal mailbox user logging into `/webmail` (Roundcube) or
`/sso/login` sees only their own account settings. Additionally every domain uses the **same
single MX hostname** `mail.<primary>.com`, so nothing in a user's client config reveals sibling
domains.

---

## Repository layout to create

```
server/
├─ MAIL-SERVER-PLAN.md            # this plan, committed to repo
├─ docker-compose.yml             # the stack
├─ .env.example / .env            # compose-level: versions, paths, host ports, profiles
├─ mailu.env.example / mailu.env  # Mailu application settings (all feature toggles)
├─ .gitignore                     # ignore .env, mailu.env, data/, certs/
├─ overrides/                     # config drop-ins (avoids custom Dockerfiles)
│  ├─ postfix/  dovecot/  nginx/  rspamd/  roundcube/
├─ ops/
│  ├─ nginx/mail.vhost.conf.example    # host nginx server block
│  ├─ certs/certbot-deploy-hook.sh     # copy renewed cert into Mailu + reload front
│  ├─ fail2ban/{jail.d,filter.d}       # host fail2ban jail reading Mailu logs
│  └─ backup/{Dockerfile,backup.sh,restore.sh,entrypoint.sh}
├─ scripts/
│  ├─ preflight.sh                # verify port 25 egress, DNS, PTR, free ports, RAM/disk
│  ├─ bootstrap.sh                # create host data dirs + permissions + secrets
│  └─ mailu.sh                    # wrapper: docker compose exec admin flask mailu …
└─ docs/
   ├─ DNS.md                      # per-domain Namecheap records (MX/SPF/DKIM/DMARC)
   ├─ SMTP-CLIENTS.md             # PHP + Node.js send examples
   ├─ API.md                      # create domain/mailbox via REST
   ├─ BACKUP-RESTORE.md
   └─ RUNBOOK.md                  # start/stop/upgrade/troubleshoot/deliverability
```

---

## Persistent storage design (the "mail must never be lost" requirement)

Single root on the VPS: `MAILU_DATA_ROOT=/srv/mailu` (overridable in `.env`). **Bind mounts,
not anonymous/named volumes**, so data is visible, backup-able, and immune to
`docker compose down -v`.

| Host path | Container mount | Contains |
|---|---|---|
| `${ROOT}/mail` | `imap:/mail` | **Maildir — all messages** |
| `${ROOT}/mailqueue` | `smtp:/queue` | Postfix spool (in-flight mail) |
| `${ROOT}/data` | `admin:/data` | `main.db` (SQLite: domains, users, aliases) |
| `${ROOT}/dkim` | `admin:/dkim` | Per-domain DKIM private keys |
| `${ROOT}/certs` | `front:/certs` | TLS cert/key |
| `${ROOT}/redis` | `redis:/data` | Rate-limit + session state |
| `${ROOT}/filter` | `antispam:/var/lib/rspamd` | Bayes/fuzzy learning |
| `${ROOT}/webmail` | `webmail:/data` | Roundcube DB, prefs, contacts |
| `${ROOT}/dav` | `webdav:/data` | Radicale (optional profile) |
| `${ROOT}/overrides` | `*:/overrides:ro` | Config drop-ins from repo |
| `${ROOT}/backups` | `backup:/backups` | Restic repo (if local target) |

Rules baked into the compose file: every service `restart: unless-stopped`; `docker compose
down` never removes these (they're host paths); `bootstrap.sh` creates them with correct
ownership before first start.

---

## TLS + host nginx integration (chosen approach)

Mailu needs a certificate for **both** the web UI and the SMTP/IMAP ports, but nginx already
owns 80/443, so Mailu's built-in Let's Encrypt (`TLS_FLAVOR=letsencrypt`) cannot run.

Chosen: **`TLS_FLAVOR=cert`** — host certbot owns the certificate, Mailu consumes a copy.

1. Host certbot issues `mail.<primary>.com` (webroot challenge served by existing nginx).
2. `ops/certs/certbot-deploy-hook.sh` copies `fullchain.pem` → `${ROOT}/certs/cert.pem` and
   `privkey.pem` → `${ROOT}/certs/key.pem`, then `docker compose restart front`.
   Installed at `/etc/letsencrypt/renewal-hooks/deploy/` so renewals are automatic.
3. Mailu `front` publishes web on loopback only: `127.0.0.1:${FRONT_HTTP_PORT}:80`
   (default **8008**) and `127.0.0.1:${FRONT_HTTPS_PORT}:443` (default **8443**).
4. Host nginx vhost for `mail.<primary>.com`: TLS terminate → `proxy_pass
   http://127.0.0.1:8008` with `X-Forwarded-For`, `X-Forwarded-Proto`, WebSocket upgrade,
   and `client_max_body_size` matched to `MESSAGE_SIZE_LIMIT`.
5. In `mailu.env`: `REAL_IP_HEADER=X-Forwarded-For` **and** `REAL_IP_FROM=${SUBNET}` (the
   Mailu docker subnet — this is what the container actually sees as source after Docker's
   port proxy). Setting `REAL_IP_HEADER` without `REAL_IP_FROM` is a spoofing vulnerability.
   `PROXY_PROTOCOL` stays **unset** (it is mutually exclusive with `REAL_IP_HEADER`).
6. Mail protocol ports are published normally on `0.0.0.0` — they do **not** conflict with
   nginx: `25, 465, 587, 993, 4190` (+ `143`, `995` optional via `PORTS`).

**Gotcha to encode:** Mailu's default `PORTS` list omits `587` and `143`. Must set
`PORTS=25,80,443,465,587,993,4190` so backend apps can use submission/STARTTLS on 587.

---

## Env-driven toggles (the "enable/disable via env" requirement)

Two files, both generated from committed `.example` templates by `bootstrap.sh`.

**`.env` — infrastructure knobs (read by Compose)**
- `MAILU_VERSION` (pin e.g. `2024.06`), `MAILU_DATA_ROOT`, `TZ`
- `BIND_ADDRESS4` / `BIND_ADDRESS6`, `SUBNET`, `SUBNET6`
- `FRONT_HTTP_PORT`, `FRONT_HTTPS_PORT`, `SMTP_PORT`, `SUBMISSION_PORT`, `SUBMISSIONS_PORT`,
  `IMAPS_PORT`, `SIEVE_PORT`
- `COMPOSE_PROFILES` — **the master on/off switch for optional containers**:
  `webmail`, `webdav`, `fetchmail`, `antivirus`, `backup`. Remove a name → that container is
  simply not created. Default: `webmail,backup`.

**`mailu.env` — application behaviour (read by every Mailu container)**
- Identity: `SECRET_KEY`, `DOMAIN`, `HOSTNAMES`, `POSTMASTER`, `SITENAME`, `WEBSITE`, `LOGO_URL`
- TLS: `TLS_FLAVOR=cert`, `TLS_CERT_FILENAME`, `TLS_KEYPAIR_FILENAME`, `OUTBOUND_TLS_LEVEL`
- Features: `WEBMAIL=roundcube|none`, `ADMIN=true`, `API=true`, `WEBDAV=none|radicale`,
  `ANTIVIRUS=none|clamav`, `FETCHMAIL_ENABLED`, `FULL_TEXT_SEARCH`, `DMARC_SEND_REPORTS`
- Paths: `WEB_ADMIN=/admin`, `WEB_WEBMAIL=/webmail`, `WEB_API=/api`, `WEBROOT_REDIRECT=/sso/login`
- Limits/abuse: `MESSAGE_SIZE_LIMIT`, `MESSAGE_RATELIMIT`, `MESSAGE_RATELIMIT_EXEMPTION`,
  `AUTH_RATELIMIT_IP`, `AUTH_RATELIMIT_USER`, `AUTH_RATELIMIT_EXEMPTION`, `DEFAULT_QUOTA`,
  `DEFAULT_SPAM_THRESHOLD`, `RECIPIENT_DELIMITER=+`
- Relay/integration: `RELAYNETS`, `RELAYHOST`/`RELAYUSER`/`RELAYPASSWORD` (smart-host
  fallback if the provider ever blocks 25), `WILDCARD_SENDERS`
- Bootstrap: `INITIAL_ADMIN_ACCOUNT`, `INITIAL_ADMIN_DOMAIN`, `INITIAL_ADMIN_PW`,
  `INITIAL_ADMIN_MODE=ifmissing`
- API: `API_TOKEN` (long random), `AUTH_REQUIRE_TOKENS`
- Proxy: `REAL_IP_HEADER`, `REAL_IP_FROM`, `SESSION_COOKIE_SECURE=True`, `SESSION_TIMEOUT`
- Perf: `LD_PRELOAD=/usr/lib/libhardened_malloc.so` (x86_64 with AVX2), `COMPRESSION=zstd`,
  `LOG_LEVEL`

Any of these is changed with an edit + `docker compose up -d` — no image rebuild.

---

## Dockerfiles

Mail components use **official pinned `ghcr.io/mailu/*` images**; customisation goes through
`overrides/` (Postfix/Dovecot/nginx/Rspamd/Roundcube config drop-ins), which is the supported
path and survives upgrades. Writing a custom Dockerfile per mail component would fork the
upstream build for no benefit.

The **one** Dockerfile we author is `ops/backup/Dockerfile` — a small Alpine image with
`restic`, `sqlite`, `rclone` and a cron entrypoint for the encrypted backup sidecar.

---

## Implementation phases

### Phase 0 — Preflight (blocks everything)
1. Write `scripts/preflight.sh`: check outbound 25 (`nc -zv gmail-smtp-in.l.google.com 25`),
   that host ports 25/465/587/993/4190/8008/8443 are free, RAM/disk, docker + compose v2
   versions, and that `mail.<primary>.com` A record + **PTR/rDNS** resolve to the VPS IP.
2. Record the chosen primary hostname and the full domain list in `docs/DNS.md`.

### Phase 1 — Scaffolding *(parallel with Phase 0)*
3. Create repo skeleton, `.gitignore` (must exclude `.env`, `mailu.env`, `data/`, `certs/`,
   `*.key`, `*.pem`).
4. Author `.env.example` and `mailu.env.example` with every variable above, grouped and
   commented with its effect and default.
5. Author `scripts/bootstrap.sh`: generate `SECRET_KEY` (16 bytes) + `API_TOKEN` (32 bytes) via
   `openssl rand`, copy `.example` → live files, `mkdir -p` all bind-mount dirs, `chmod 700`
   the secret-bearing dirs (`certs`, `dkim`, `data`).

### Phase 2 — Compose stack *(depends on 3–5)*
6. Author `docker-compose.yml` with services `resolver`, `redis`, `front`, `admin`, `imap`,
   `smtp`, `oletools`, `antispam`, and profile-gated `webmail`, `webdav`, `fetchmail`,
   `antivirus`, `backup`.
   - All images pinned `ghcr.io/mailu/<svc>:${MAILU_VERSION}`.
   - `env_file: [mailu.env]` on every Mailu service.
   - `restart: unless-stopped` + healthchecks everywhere.
   - `resolver` gets a static IP `${SUBNET%.*}.254`; every other service sets `dns:` to it.
   - `logging: json-file` with `max-size`/`max-file` caps so logs can't fill the disk.
   - `front` port mapping exactly as described in the TLS section (web on loopback, mail on
     public bind address).
   - All bind mounts from the storage table.
7. `docker compose config` must parse cleanly with the example envs.

### Phase 3 — Edge TLS + nginx *(depends on Phase 2)*
8. Author `ops/nginx/mail.vhost.conf.example` (80 → 301 https + ACME webroot; 443 → proxy to
   `127.0.0.1:${FRONT_HTTP_PORT}`, forwarded headers, upgrade headers, large body size).
9. Author `ops/certs/certbot-deploy-hook.sh` (copy + `chmod 600` + `docker compose restart front`).
10. Document install steps in `docs/RUNBOOK.md`: issue cert, symlink vhost, `nginx -t`, reload,
    place the deploy hook, run it once.

### Phase 4 — First bring-up *(depends on 6–10)*
11. `bootstrap.sh` → `docker compose up -d` → verify all healthy.
12. Admin account is auto-created by `INITIAL_ADMIN_*`; log into `https://mail.<primary>.com/admin`,
    change the password, confirm the `POSTMASTER` alias exists (missing postmaster causes
    obscure failures).

### Phase 5 — Domains, DKIM, DNS *(depends on Phase 4)*
13. For each domain: add in `/admin` → **Domains**, then *Generate keys* for DKIM.
14. `docs/DNS.md` gives the Namecheap Advanced-DNS table per domain:
    - `MX  @  →  mail.<primary>.com` (priority 10)
    - `TXT @  →  v=spf1 mx a:mail.<primary>.com -all`
    - `TXT dkim._domainkey → <value copied from Mailu admin>`
    - `TXT _dmarc → v=DMARC1; p=quarantine; rua=mailto:dmarc@<domain>; adkim=s; aspf=s`
    - optional `CNAME autoconfig/autodiscover → mail.<primary>.com`
    - plus the one-time `A mail → <VPS IP>` and provider-side **PTR**.
15. Create mailboxes (`info@a.com`, `support@a.com`, `abc@b.com`, …) — all users, no admin flag.

### Phase 6 — Backend SMTP integration *(parallel with Phase 5, after Phase 4)*
16. Create dedicated per-application accounts (e.g. `no-reply@a.com`) with
    `MESSAGE_RATELIMIT_EXEMPTION` if they need volume; never reuse a human mailbox.
17. `docs/SMTP-CLIENTS.md`: host `mail.<primary>.com`, port **587** STARTTLS or **465**
    implicit TLS, auth = full email + password.
    - PHP: PHPMailer / Laravel `MAIL_*` block.
    - Node: Nodemailer transport config.
    - Credentials via the app's own env/secret store, never hardcoded.
18. If an app runs in Docker on the same host, optionally attach it to the Mailu network and
    document the `RELAYNETS` alternative — **with an explicit warning** that a wrong CIDR turns
    the server into an open relay; authenticated submission is the recommended default.
19. `docs/API.md`: `curl` + Node examples hitting `/api/v1/user` and `/api/v1/domain` with the
    `Authorization: <API_TOKEN>` header for programmatic mailbox creation; SwaggerUI at `/api/`.

### Phase 7 — Hardening *(depends on Phase 4)*
20. Rely primarily on Mailu's built-in rate limiting (`AUTH_RATELIMIT_IP`,
    `AUTH_RATELIMIT_USER`, `AUTH_RATELIMIT_EXEMPTION_LENGTH`) — it is subnet-aware and
    already tuned.
21. Add `ops/fail2ban/` jail + filter for the host, parsing Mailu `front`/`admin` container
    logs, banning via nftables/iptables for repeated auth failures.
22. `ufw`: allow 25, 465, 587, 993, 4190 (and 143/995 only if enabled); ensure 8008/8443 are
    never exposed (loopback binding already enforces this).
23. Set `SESSION_COOKIE_SECURE=True`, strong `DEFAULT_QUOTA`, `MESSAGE_RATELIMIT` per user, and
    keep `API_TOKEN` out of git.

### Phase 8 — Backups & restore drill *(depends on Phase 4)*
24. `ops/backup/Dockerfile` + `backup.sh`: nightly cron →
    - `sqlite3 /data/main.db ".backup /snapshot/main.db"` (consistent snapshot, not a live copy)
    - `restic backup` of `mail/`, `data/main.db snapshot`, `dkim/`, `webmail/`, `filter/`,
      `mailqueue/`, `certs/` with `RESTIC_PASSWORD` from env (encrypted at rest)
    - retention `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`, then `restic prune`
    - target configurable via env: local `${ROOT}/backups` or remote S3/B2/SFTP via rclone.
25. `restore.sh` + `docs/BACKUP-RESTORE.md`, and **actually perform a restore drill** into a
    scratch directory before declaring done.

### Phase 9 — Verification & docs *(depends on all)*
26. Fill `docs/RUNBOOK.md`: daily ops, upgrade procedure (bump `MAILU_VERSION`, read release
    notes, `docker compose pull && up -d`), log locations, common failures.
27. Run the full verification checklist below.

---

## Verification

1. `docker compose config` parses; `docker compose ps` shows every enabled service `healthy`.
2. **Inbound:** send from an external Gmail account to `info@a.com` and `abc@b.com`; both land
   in the right mailbox in Roundcube. Check `Authentication-Results` headers show `spf=pass`,
   `dkim=pass`, `dmarc=pass`.
3. **Outbound:** send from `info@a.com` to `check-auth@verifier.port25.com` and to
   `https://www.mail-tester.com` — target **10/10**, SPF/DKIM/DMARC all pass, no blacklist hits.
4. **Multi-domain isolation:** log in as `abc@b.com` at `/webmail` and at `/sso/login`; confirm
   no Domains menu, no other-domain data, and `/admin` is refused.
5. **Backend SMTP:** run the PHP and Node.js snippets from `docs/SMTP-CLIENTS.md` against
   port 587 and 465 — both deliver. Then confirm an *unauthenticated* `swaks` from an external
   host is rejected (open-relay test).
6. **API:** create a mailbox via `POST /api/v1/user` with the token; verify it appears in the
   panel and can receive mail. Verify a request with a bad/absent token returns 401.
7. **Persistence:** `docker compose down && docker compose up -d` → all old mail still present
   in IMAP. Repeat with a host reboot.
8. **Restore drill:** wipe a scratch copy, `restore.sh` from restic, confirm maildir + `main.db`
   integrity (`sqlite3 ... "PRAGMA integrity_check"`).
9. **TLS renewal:** `certbot renew --dry-run`, then run the deploy hook and confirm
   `openssl s_client -connect mail.<primary>.com:993` shows the new cert.
10. **Rate limiting/fail2ban:** repeated bad logins get throttled and produce a ban.

---

## Decisions

- **Mailu** over docker-mailserver/Mailcow/Poste.io — only option with a first-class
  multi-domain admin panel where the domain list is invisible to non-admin users.
- **Bind mounts under `/srv/mailu`**, not named volumes — explicit, backup-friendly, survives
  `down -v`.
- **`TLS_FLAVOR=cert`** with host-certbot + deploy hook, because existing nginx owns 80/443.
  Mailu's own Let's Encrypt is unusable here.
- **`REAL_IP_HEADER` + `REAL_IP_FROM`**, not `PROXY_PROTOCOL` — simpler with plain nginx
  `proxy_pass`; the two are mutually exclusive.
- **No custom Dockerfiles for mail components**; use pinned upstream images + `overrides/`.
  One authored Dockerfile for the backup sidecar.
- **Optional services gated by Compose profiles** so `COMPOSE_PROFILES` in `.env` is a real
  on/off switch, not just a config flag.
- **ClamAV excluded** by default (not selected); wired behind the `antivirus` profile so it can
  be enabled later with one env edit.
- **Authenticated submission (587/465) is the supported path for backend apps**; `RELAYNETS` is
  documented but discouraged.
- **Out of scope:** migrating existing mailboxes from a current provider, HA/multi-node,
  clustering, calendar/contacts beyond optional Radicale, and any custom-built admin UI
  (Mailu's panel already satisfies the requirement).

---

## Further considerations

1. **Where should the encrypted backups land?**
   A) Local `/srv/mailu/backups` only (simplest, but lost if the VPS dies) ·
   B) **Local + remote S3-compatible (Backblaze B2 / Wasabi / R2) via restic** — *recommended* ·
   C) Remote SFTP to another box you own.

2. **Database backend for Mailu's config?**
   A) **SQLite** (upstream default and recommendation, tiny dataset, fewer moving parts) —
   *recommended* · B) PostgreSQL container (only if you later need external tooling to query
   the mailbox table directly).

3. **Full-text search indexing?**
   A) `FULL_TEXT_SEARCH=en` (fast webmail search, more RAM + disk) — *recommended* for 8 GB ·
   B) `off` (leanest) · C) Multiple languages if you expect non-English mail.

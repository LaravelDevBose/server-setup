# Build Status — Multi-Domain Mail Server (Mailu)

Cross-referenced against [MAIL-SERVER-PLAN.md](MAIL-SERVER-PLAN.md), item by item, by reading
the code in this repository and inspecting the running stack — not by inferring
from filenames.

Legend: **DONE** · **PARTIAL** · **TODO** · **DROPPED** (deliberate deviation)

**Verified at time of writing:** stack up 58 min, all services healthy —
`resolver, front, admin, imap, smtp, oletools, antispam, webmail` healthy;
`redis, backup` running (upstream images ship no healthcheck for these two).
Live DB: **5 domains**, **6 users** (2 global admin), 0 aliases. **1 restic snapshot** exists.

---

## Summary by phase

| Phase | Scope | Status |
|---|---|---|
| 0 | Preflight | DONE as a checklist (not a script) |
| 1 | Scaffolding, env templates, bootstrap | **DONE** |
| 2 | Compose stack | **DONE** |
| 3 | Edge TLS + nginx | DONE (authored + self-signed path proven); unapplied on VPS |
| 4 | First bring-up | **DONE** — verified running now |
| 5 | Domains, DKIM, DNS | DONE locally (2 DKIM keys, 5 domains); public DNS pending |
| 6 | Backend SMTP + API | **DONE** |
| 7 | Hardening | **DONE** — fail2ban jails written and regex-validated |
| 8 | Backups & restore | **DONE** — drill executed, found and fixed a silent data-loss bug |
| 9 | Verification & docs | PARTIAL — all host-side checks pass; external checks need the VPS |

---

## Phase 0 — Preflight

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 1 | `scripts/preflight.sh` (25/egress, free ports, RAM/disk, docker ver, A + PTR) | DROPPED (fully covered) | Reimplemented as a copy-paste checklist in [docs/DEPLOY.md](docs/DEPLOY.md) §1 — `nc -zv gmail-smtp-in…25`, `dig +short`, `dig +short -x` (PTR), `ss -lntp` port-conflict check, plus `free -g` / `nproc` / `df -h` / `docker compose version`. The resource and version checks were missing until reviewed against the plan |
| 2 | Record primary hostname + domain list | PARTIAL | Everything still says `mail.example.com`; real hostname and the production domain list are not yet chosen |

## Phase 1 — Scaffolding

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 3 | Repo skeleton + `.gitignore` | **DONE** | [.gitignore](.gitignore) excludes `.env`, `mailu.env`, `docker-compose.override.yml`, `data/`, `*.pem`, `*.key`, `*.crt` |
| 4 | `.env.example` + `mailu.env.example`, every var grouped and commented | **DONE** | [.env.example](.env.example), [mailu.env.example](mailu.env.example). Checked against the plan's variable list — all present, incl. `PORTS=25,80,443,465,587,993,4190`, `REAL_IP_FROM`, `PROXY_PROTOCOL` left empty, `WILDCARD_SENDERS`, `AUTH_RATELIMIT_EXEMPTION_LENGTH`, `RECIPIENT_DELIMITER` |
| 5 | `bootstrap.sh` — secrets, dirs, permissions | **DONE (exceeds plan)** | [scripts/bootstrap.sh](scripts/bootstrap.sh): idempotent; generates `SECRET_KEY` (16 hex chars, Mailu's required length), `API_TOKEN` (32 bytes), `RESTIC_PASSWORD` (24 bytes); `chmod 700` on `certs`/`dkim`/`data`; BSD-vs-GNU `sed -i` shim; **plus** a self-signed cert so `TLS_FLAVOR=cert` works before certbot exists |

## Phase 2 — Compose stack

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 6 | 8 core services + 5 profile-gated optional | **DONE** | [docker-compose.yml](docker-compose.yml): `resolver, redis, front, admin, imap, smtp, oletools, antispam` + profiles `webmail, webdav, fetchmail, antivirus, backup` |
| 6a | Pinned images | **DONE** | `${DOCKER_ORG}/${DOCKER_PREFIX}<svc>:${MAILU_VERSION}`, pinned `MAILU_VERSION=2024.06`; ClamAV pinned `clamav/clamav-debian:1.4` |
| 6b | `env_file`, `restart: unless-stopped`, log caps | **DONE** | YAML anchors `x-mailu-common` / `x-mailu-logging` (`max-size: 10m`, `max-file: 3`) |
| 6c | Static resolver IP + `dns:` on every service | **DONE** | `RESOLVER_IP=192.168.203.254` via `ipam`, referenced from the common anchor |
| 6d | Healthchecks everywhere | **DONE in effect** | Upstream images supply them — 8 services report `(healthy)`. Compose adds only one explicit healthcheck (antivirus). `redis` and `backup` have none |
| 6e | Web on loopback, mail on bind address | **DONE** | `127.0.0.1:${FRONT_HTTP_PORT}:80` / `:8443:443`; mail on `${BIND_ADDRESS4}:{25,465,587,993,4190}` |
| 6f | All bind mounts from the storage table | **DONE** | Every path in the plan's table is mounted; `overrides/*` mounted `:ro`. Network segmentation goes beyond the plan: separate `webmail`, `radicale`, `clamav` bridges and an `internal: true` `oletools` bridge |
| 7 | `docker compose config` parses | **DONE** | parses; the stack is running from it |

> Encoded gotcha (from prior debugging): `SUBNET` is injected via `environment:` in the common
> anchor *and* on the resolver, because Mailu's unbound template consumes it. Without it the
> resolver crash-loops on `unbound.conf:11: error: unknown keyword`.

## Phase 3 — Edge TLS + nginx

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 8 | nginx vhost template | **DONE** | [ops/nginx/mail.vhost.conf.example](ops/nginx/mail.vhost.conf.example) |
| 9 | certbot deploy hook | **DONE** | [ops/certs/certbot-deploy-hook.sh](ops/certs/certbot-deploy-hook.sh) — env-overridable `MAIL_HOST`/`STACK_DIR`/`CERT_DIR`, `install -m 644` cert / `-m 600` key, then `docker compose restart front` |
| 10 | Install steps documented | **DONE** | [docs/DEPLOY.md](docs/DEPLOY.md) §3–§4, incl. the `client_max_body_size` ≥ `MESSAGE_SIZE_LIMIT` warning and `certbot renew --dry-run` |
| — | Cert issued / vhost installed on the VPS | TODO | requires the server |

## Phase 4 — First bring-up

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 11 | bootstrap → `up -d` → all healthy | **DONE** | verified live: 10 containers up, 8 healthy, 2 without healthchecks |
| 12 | Admin auto-created; postmaster confirmed | **DONE** | `admin@example.com` created via `INITIAL_ADMIN_*`, `global_admin=1`, web login verified (302 → `/admin`). The earlier `admin@example.test` was web-locked — see D2. Note: the alias table is empty; postmaster is served by the admin *account*, not an alias row |

## Phase 5 — Domains, DKIM, DNS

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 13 | Add domain + generate DKIM | **DONE** | 5 domains provisioned (`a.test`, `b.test`, `example.test`, `alpha.example.com`, `beta.example.com`); DKIM keys on disk for `a.test` and `b.test`. [scripts/mailu.sh](scripts/mailu.sh) wraps `flask mailu` |
| 14 | Per-domain DNS record table | **DONE (better than planned)** | `docs/DNS.md` replaced by [scripts/dns-records.sh](scripts/dns-records.sh), which pulls `dns_mx`/`dns_spf`/`dns_dkim`/`dns_dmarc`/`dns_autoconfig` from the REST API so it can never drift from the live DKIM key. Includes Namecheap-specific formatting notes and the one-time A + PTR reminder |
| 15 | Create mailboxes, no admin flag | **DONE** | `info@a.test`, `support@a.test`, `abc@b.test`, `staff@beta.example.com` — all `global_admin=0` |
| — | Records published at Namecheap + PTR set | TODO | needs the real domains |

> Encoded gotcha: the web UI rejects `.test`/`.local` ("Invalid email address"); SMTP and the
> REST API accept them. `alpha./beta.example.com` exist precisely to exercise the UI path.

## Phase 6 — Backend SMTP integration

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 16 | Dedicated per-app accounts | **DONE** | [docs/SMTP-CLIENTS.md](docs/SMTP-CLIENTS.md) |
| 17 | PHP + Node examples, 587 STARTTLS / 465 TLS | **DONE** | same; credentials sourced from app env, explicitly "never commit" |
| 18 | `RELAYNETS` documented **with** open-relay warning | **DONE** | `RELAYNETS=` left empty with a `# DANGER:` comment; DEPLOY.md spells out that any local process on the VPS can relay via port 25 |
| 19 | REST API for domain/user/DKIM | **DONE** | `docs/API.md` merged into SMTP-CLIENTS.md — `POST /api/v1/domain`, `POST /api/v1/user`, `POST /api/v1/domain/<d>/dkim` |

## Phase 7 — Hardening

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 20 | Mailu built-in rate limiting | **DONE** | `AUTH_RATELIMIT_IP=5/hour`, `AUTH_RATELIMIT_USER=50/day`, `AUTH_RATELIMIT_EXEMPTION_LENGTH`, `MESSAGE_RATELIMIT=200/day` |
| 21 | `ops/fail2ban/` jail + filter | **DONE** | [ops/fail2ban/](ops/fail2ban/jail.d/mailu.local) — two jails (`mailu-auth`, `mailu-web`) + two filters, reading the `front` container's journal via [compose.journald.yml](ops/fail2ban/compose.journald.yml) (scopes journald to `front` only; every other service keeps size-capped `json-file`). Regexes were written against **captured live log lines**, not guessed, and validated: 5 positives extract the right host, 3 negatives correctly ignored — including a successful `302` login and Dovecot's "no auth attempts" probe. Install steps in [docs/DEPLOY.md](docs/DEPLOY.md) §7 |
| 22 | `ufw` rules; 8008/8443 never exposed | **DONE** | DEPLOY.md §6; loopback binding structurally enforced in compose |
| 23 | `SESSION_COOKIE_SECURE`, quotas, token out of git | **DONE** | `SESSION_COOKIE_SECURE=True`, `DEFAULT_QUOTA=1 GB`, `DEFAULT_SPAM_THRESHOLD=80`; `mailu.env` gitignored |

## Phase 8 — Backups & restore

| # | Plan task | Status | Evidence |
|---|---|---|---|
| 24 | Backup sidecar | **DONE — and proven by execution** | [ops/backup/Dockerfile](ops/backup/Dockerfile) Alpine + restic/sqlite; [backup.sh](ops/backup/backup.sh) auto-`init`s the repo, retention 7/4/6 + `--prune`, and adds `restic check --read-data-subset=1%`. [entrypoint.sh](ops/backup/entrypoint.sh) fails fast on empty `RESTIC_PASSWORD` and persists env for busybox cron. **1 snapshot present**, covering `mail, mailqueue, dkim, certs, data, webmail, filter, /tmp/stage` |
| 24a | *Deviation:* SQLite consistency method | note | Plan said `.backup`; implementation dumps to `*.sql` and excludes `*.db`/`-wal`/`-shm` from restic. The dump now runs against a staged copy rather than the read-only mount — see D3 for why that matters |
| 25 | `restore.sh` + docs | **DONE** | [ops/backup/restore.sh](ops/backup/restore.sh), [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) |
| — | Restore drill executed | **DONE — and it caught a real defect (D3)** | Restored 207 files / 84.8 MiB to scratch; maildir file count matches live (21/21) with a byte-identical spot check; DKIM keys and certs present; both DBs rebuild with `integrity_check = ok` |

## Phase 9 — Verification & docs

| # | Plan check | Status | Evidence |
|---|---|---|---|
| 1 | config parses; services healthy | **DONE** | verified live |
| 2 | Inbound from Gmail; spf/dkim/dmarc pass | TODO | needs public DNS |
| 3 | Outbound to mail-tester / port25 verifier | TODO | needs public DNS |
| 4 | Multi-domain isolation | **DONE** | non-admin: no Domains nav item, no listing on `/admin/domain`, 403 on `/admin/admin/list` and `/admin/relay` |
| 5 | Backend SMTP 587 + 465; relay rejected | **PARTIAL** | [scripts/smoke-test.py](scripts/smoke-test.py) — 4 checks pass: authenticated send on 587 STARTTLS and on 465 implicit TLS, plus both ports returning `530` for unauthenticated relay. Port-25 relay is **structurally untestable from the host** (Docker's userland proxy rewrites the source IP into `SUBNET`, which is in Postfix `mynetworks`); must be re-run off-host with `swaks` |
| 6 | API create-user with token; 401 without | **DONE** | Automated in [scripts/smoke-test.py](scripts/smoke-test.py). Actual behaviour differs from the plan's assumption: **absent token → 401, invalid token → 403** (both correctly rejected). Also asserts a rejected write creates nothing — confirmed no `intruder` row reached the DB. Checks proven non-vacuous by mutation: wrong endpoint and a falsified token both make them fail |
| 7 | Persistence across down/up and reboot | **DONE (down/up)** | data survives on bind mounts; host-reboot test pending on the VPS |
| 8 | Restore drill + `PRAGMA integrity_check` | **DONE** | both databases rebuilt from dumps, `integrity_check = ok`; uncovered and fixed D3 |
| 9 | `certbot renew --dry-run` + cert on 993 | TODO | needs the VPS |
| 10 | Rate limiting / fail2ban ban observed | PARTIAL | jails + filters built and regex-validated offline; an actual ban must still be observed on the VPS (needs systemd/nftables) |
| — | `docs/RUNBOOK.md` | DROPPED | upgrade steps + troubleshooting matrix live in DEPLOY.md; dangling pointers cleaned up (D1) |

---

## Defects found while cross-referencing

| id | Issue | Location |
|---|---|---|
| ~~D1~~ | **FIXED** — both references now point to DEPLOY.md §"Open-relay test". Verified: no `RUNBOOK` references remain anywhere, every `docs/`/`ops/`/`scripts/` path in the repo resolves, and the suite still passes 4/4 | [scripts/smoke-test.py](scripts/smoke-test.py) |
| ~~D2~~ | **FIXED** — was worse than cosmetic drift: the live env used `example.test`, the exact special-use TLD the template warns against, so `admin@example.test` was rejected at the web login with "Invalid email address" (reproduced before fixing). Live env repointed to `example.com`, self-signed cert regenerated to match, stack recreated → `admin@example.com` auto-created and **login now returns 302 → `/admin`**. Root cause closed: [bootstrap.sh](scripts/bootstrap.sh) now refuses `.test`/`.local`/`.internal`/`.example`/`.invalid`/`localhost` for `DOMAIN` and `INITIAL_ADMIN_DOMAIN` | [mailu.env](mailu.env.example), [scripts/bootstrap.sh](scripts/bootstrap.sh) || ~~D3~~ | **FIXED — silent data loss.** `roundcube.db` is in **WAL** mode, which needs to create `-wal`/`-shm` sidecars; the read-only source mount forbids that, so `.dump` failed with `SQLITE_CANTOPEN (14)` and wrote a 125-byte error stub. Because `sqlite3 .dump` **exits 0 even when it aborts**, `set -e` never fired and the nightly job reported success. With `*.db` also excluded from restic, **Roundcube identities, contacts and preferences were in no backup at all**. `main.db` was unaffected (journal mode `delete`, which works read-only) — which is exactly why the bug stayed invisible. Now dumps from a copy staged on writable storage, and verifies the dump ends in `COMMIT;`. Re-verified: roundcube dump 125 B → 6430 B, 17 tables incl. `contacts`/`identities`, `integrity_check = ok` | [ops/backup/backup.sh](ops/backup/backup.sh) |
## Deliberate deviations from the plan

- `scripts/preflight.sh` → manual checklist in DEPLOY.md §1, now covering everything the
  script was specified to check.
- `docs/DNS.md` → `scripts/dns-records.sh`, generated from the API so it cannot drift.
- `docs/API.md` → merged into `docs/SMTP-CLIENTS.md`.
- `docs/RUNBOOK.md` → merged into `docs/DEPLOY.md`.
- `overrides/` lives at `data/overrides/`, mounted read-only, rather than at the repo root.
- SQLite backup uses `.dump` rather than `.backup` (the read-only mount requires it).
- `.env.example` defaults target **local testing** — loopback binds, high mail ports
  (2525/4465/5587/9993). Production values are listed in DEPLOY.md §2.

## Remaining work, in order

**Everything runnable without the VPS is done.** The 8-check smoke test passes end to end:
4 SMTP + 4 API.

1. Choose the real primary hostname + domain list; replace `mail.example.com` throughout.
   This gates everything below.
2. On the VPS: preflight → deploy → certbot → nginx vhost → publish DNS + PTR → install fail2ban.
3. Off-host open-relay test with `swaks`, then mail-tester/port25 deliverability, the
   reboot-persistence test, and a fail2ban ban observation.

Optional cleanup: the local DB still carries the D2-era workaround objects — domain
`example.test`, the web-locked `admin@example.test`, and the stand-in admin
`root@alpha.example.com`. Harmless, but they are test residue rather than intended state.

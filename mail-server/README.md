# Multi-domain mail server (Mailu + Docker Compose)

One mail server hosting many independent domains. Mailboxes are managed from an
admin panel; ordinary users never see the list of domains you host. Backend apps
(PHP/Node/…) send through authenticated SMTP submission. All mail is stored on
host bind mounts, so nothing is lost when containers stop, restart, or are removed.

## Layout

```
docker-compose.yml      the stack; optional services gated by COMPOSE_PROFILES
.env                    infrastructure: versions, data root, host ports, profiles
mailu.env               application behaviour: every Mailu feature toggle
scripts/bootstrap.sh    one-time setup: secrets, data dirs, self-signed cert
scripts/mailu.sh        wrapper around Mailu's CLI
scripts/dns-records.sh  prints the exact DNS records for each domain
scripts/smoke-test.py   SMTP + API verification
ops/nginx/              host nginx vhost template
ops/certs/              certbot deploy hook
ops/fail2ban/           jails, filters and the journald compose overlay
ops/backup/             restic backup sidecar (Dockerfile + scripts)
docs/                   admin guide, user guide, deployment, SMTP clients, backup
data/                   ALL persistent state (gitignored)
```

## Quick start (local)

```bash
./scripts/bootstrap.sh
docker compose up -d
```

Then open <https://localhost:8443/> and accept the self-signed certificate
warning. The initial admin comes from `INITIAL_ADMIN_*` in `mailu.env`.

The defaults in `.env.example` are tuned for local testing: everything binds to
`127.0.0.1` and mail ports are remapped high (2525/4465/5587/9993) so nothing
needs privileges. See [docs/DEPLOY.md](docs/DEPLOY.md) for the production values.

Reset the local environment completely:

```bash
docker compose down && rm -rf data
```

## Adding a domain and mailboxes

Through the panel: **Mail domains → New domain**, then *Generate keys* for DKIM
on the domain's Details page, then **Users → Add user**. Or from the command line:

```bash
./scripts/mailu.sh domain a.com
./scripts/mailu.sh user info a.com 'strong-password'
./scripts/dns-records.sh a.com          # records to paste into Namecheap
```

Generating the DKIM key and publishing the DNS records are not optional — skip
them and mail is delivered unsigned, straight to spam. Full walkthrough in
[docs/ADMIN-GUIDE.md](docs/ADMIN-GUIDE.md).

Every domain shares the single hostname in `HOSTNAMES`, so a user's mail client
settings never reveal the other domains you host.

## Enabling and disabling features

Two switches, no image rebuilds:

- `COMPOSE_PROFILES` in `.env` decides which optional **containers** exist
  (`webmail`, `webdav`, `fetchmail`, `antivirus`, `backup`).
- `mailu.env` decides application **behaviour** (quotas, rate limits, spam
  thresholds, relay host, API on/off, …).

Apply either with `docker compose up -d`.

Enabling ClamAV needs both, because the container and the scanning setting are
separate concerns:

```bash
# .env
COMPOSE_PROFILES=webmail,backup,antivirus
# mailu.env
ANTIVIRUS=clamav
```

## Documentation

- [docs/ADMIN-GUIDE.md](docs/ADMIN-GUIDE.md) — install, add a domain, DNS, create mailboxes, admin panel reference
- [docs/USER-GUIDE.md](docs/USER-GUIDE.md) — for mailbox owners: webmail, account settings, mail client setup
- [docs/DEPLOY.md](docs/DEPLOY.md) — VPS deployment behind existing nginx, TLS, DNS, firewall, fail2ban
- [docs/SMTP-CLIENTS.md](docs/SMTP-CLIENTS.md) — sending from PHP/Node backends, and the REST API
- [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) — backup contents, restore drill

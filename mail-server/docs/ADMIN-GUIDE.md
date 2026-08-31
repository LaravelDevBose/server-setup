# Administrator guide

For whoever runs the platform: adding domains, creating mailboxes, and the DNS
that makes mail actually deliver. Assumes the stack is already installed — see
[DEPLOY.md](DEPLOY.md) for the VPS install and the [README](../README.md) for a
local test run.

Sign in at `https://mail.example.com/` with a global-admin account. The panel is
at `/admin`; ordinary users never see any of the pages below.

---

## Installing

| Where | How |
|---|---|
| Local test machine | Start Traefik first (`cd ../traefik && docker compose up -d`), then `./scripts/bootstrap.sh && docker compose up -d`. Access via the hostname in `MAIL_HOSTNAME`. |
| Production VPS | [DEPLOY.md](DEPLOY.md) — preflight, certbot, nginx vhost, firewall, fail2ban |

`bootstrap.sh` is idempotent: it creates `.env` and `mailu.env` from the
templates, generates the secrets, creates the data directories, and issues a
self-signed certificate so the stack starts before real TLS exists. Running it
again never overwrites existing files.

The first admin account comes from `INITIAL_ADMIN_*` in `mailu.env` and is
created on first start. Change its password immediately.

---

## Adding a new domain

Four steps. Skipping step 2 or 3 is the usual reason mail lands in spam.

### 1. Create the domain

**Mail domains → New domain** (`/admin/domain/create`), or:

```bash
./scripts/mailu.sh domain newclient.com
```

Set the max mailbox count and default quota here if you want them to differ from
`DEFAULT_QUOTA` in `mailu.env`.

> Do not use a special-use TLD (`.test`, `.local`, `.internal`). Mailu's login
> validator rejects those addresses, so the mailboxes work over SMTP and IMAP but
> nobody can sign in to webmail. `bootstrap.sh` refuses them for the primary
> domain for this reason.

### 2. Generate the DKIM key

Open **Mail domains → the domain → Details** (`/admin/domain/details/<domain>`)
and use *Generate keys*. Without this, outbound mail is unsigned and large
providers will treat it as suspicious.

### 3. Publish the DNS records

The panel shows the records on that same Details page. To get them all at once:

```bash
BASE_URL=https://mail.example.com ./scripts/dns-records.sh newclient.com
```

That reads them from the API, so the DKIM value always matches the live key.
In Namecheap: **Domain List → Manage → Advanced DNS**.

| Type | Host | Value | Why |
|---|---|---|---|
| MX | `@` | `mail.example.com` (priority 10) | where inbound mail goes |
| TXT | `@` | `v=spf1 mx a:mail.example.com -all` | authorises your server to send |
| TXT | `dkim._domainkey` | from the panel | signs outbound mail |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:dmarc@newclient.com` | tells receivers what to do on failure |
| CNAME | `autoconfig` / `autodiscover` | `mail.example.com` | clients self-configure |

Strip the trailing dot and the `600 IN TXT` prefix — Namecheap adds those itself.

Two records are set up once for the mail host itself, not per domain:

- `A  mail  →  <VPS public IP>`
- **PTR** (reverse DNS) `<VPS public IP> → mail.example.com`, set in your VPS
  provider's panel. Mail from a host without a PTR is widely rejected.

### 4. Verify

```bash
dig +short MX newclient.com
dig +short TXT newclient.com
dig +short TXT dkim._domainkey.newclient.com
```

Then send a message from the new domain to <https://www.mail-tester.com> and aim
for 10/10. DNS changes can take up to an hour to propagate.

---

## Creating a mailbox

**Mail domains → the domain → Users** (`/admin/user/list/<domain>`) **→ Add user**, or:

```bash
./scripts/mailu.sh user info newclient.com 'a-strong-password'
```

What the fields mean:

| Field | Notes |
|---|---|
| Email | the full address; this is also the login username |
| Password | users can change it later at `/admin/user/password` |
| Quota | defaults to `DEFAULT_QUOTA` (1 GB); 0 means unlimited |
| Enabled | off disables login without deleting any mail |
| Allow IMAP / POP3 | leave IMAP on for normal mail clients |
| Spam filter threshold | lower catches more spam and risks more false positives |
| Global admin | **leave off** for ordinary users — see the warning below |

Every domain should have a `postmaster` address, either a mailbox or an alias.
Its absence causes obscure delivery failures.

> **Global admin is what exposes the domain list.** A normal user sees only their
> own account. Tick this and they can see and edit every domain on the platform.
> Only grant it to platform operators.

### Aliases

**Mail domains → the domain → Aliases** (`/admin/alias/list/<domain>`). Use these
for `sales@`, `postmaster@`, catch-alls, or forwarding one address to several
mailboxes. An alias costs no storage; a mailbox does.

### Accounts for applications

Give each application its own mailbox — never reuse a human one. If it sends in
volume, add it to `MESSAGE_RATELIMIT_EXEMPTION` in `mailu.env`. Setup and code
examples are in [SMTP-CLIENTS.md](SMTP-CLIENTS.md).

---

## Settings that decide whether mail sends and arrives

Most delivery problems are DNS, not the server. In order of how often they bite:

| Requirement | Where | Symptom when wrong |
|---|---|---|
| PTR / reverse DNS | VPS provider panel | Gmail and Outlook reject outright |
| SPF record | domain DNS | `spf=fail`, mail lands in spam |
| DKIM key generated **and** published | panel + domain DNS | `dkim=none`, spam folder |
| DMARC record | domain DNS | inconsistent handling across providers |
| MX record | domain DNS | no inbound mail at all |
| Port 25 outbound open | VPS provider | nothing sends; queue grows |
| Certificate valid for `HOSTNAMES` | certbot + deploy hook | client TLS warnings |
| `587` present in `PORTS` | `mailu.env` | apps cannot use submission |

Check a queue that is not draining:

```bash
docker compose exec smtp postqueue -p
docker compose logs -f smtp
```

Other knobs in `mailu.env`, applied with `docker compose up -d`:

- `MESSAGE_SIZE_LIMIT` — Traefik has no body-size cap by default; set this freely
- `DEFAULT_QUOTA`, `DEFAULT_SPAM_THRESHOLD`
- `AUTH_RATELIMIT_IP`, `AUTH_RATELIMIT_USER` — brute-force limits
- `RECIPIENT_DELIMITER=+` — enables `user+tag@domain`

---

## Admin panel reference

Verified against the running panel.

| Page | Path | What it is for |
|---|---|---|
| Mail domains | `/admin/domain` | every hosted domain |
| New domain | `/admin/domain/create` | add one |
| Domain details | `/admin/domain/details/<d>` | DKIM keys and the DNS records to publish |
| Users | `/admin/user/list/<d>` | mailboxes in a domain |
| Aliases | `/admin/alias/list/<d>` | forwarding and catch-alls |
| Administrators | `/admin/admin/list` | who holds global admin |
| Relayed domains | `/admin/relay` | relay for domains hosted elsewhere |
| Antispam | `/admin/antispam/` | the Rspamd web interface |
| Announcement | `/admin/announcement` | message every user |

---

## Routine operations

```bash
docker compose ps                        # health
docker compose logs -f smtp              # delivery problems
docker compose logs -f front             # TLS, proxying, auth
./scripts/mailu.sh config-export --secrets   # full config dump

docker compose run --rm backup backup.sh     # backup now
docker compose run --rm backup restic snapshots
```

Test the backups periodically rather than trusting that they run — a broken
dump can report success for months. The procedure is in
[BACKUP-RESTORE.md](BACKUP-RESTORE.md).

Upgrades: read the release notes, bump `MAILU_VERSION` in `.env`, then
`docker compose pull && docker compose up -d`.

# Backup and restore

The `backup` profile runs a restic sidecar on a nightly schedule. Everything it
writes is encrypted with `RESTIC_PASSWORD` before it leaves the container, so the
repository can safely live on untrusted storage.

**Store `RESTIC_PASSWORD` somewhere outside this server.** Without it the backups
are unrecoverable, and a server failure would otherwise destroy both the data and
the only copy of the key.

## What is captured

| Path | Why |
|---|---|
| `mail/` | every message, in Maildir format |
| `mailqueue/` | mail accepted but not yet delivered |
| `dkim/` | per-domain signing keys — losing these breaks DKIM for every domain |
| `certs/` | TLS certificate and key |
| `data/`, `webmail/` | domain, user and Roundcube configuration |
| `filter/` | Rspamd's learned spam/ham |

SQLite databases are dumped with `.dump` rather than copied. Copying a live
database file can capture a half-written transaction; the raw `.db` files are
excluded from the snapshot for that reason and the SQL dumps are stored instead.

## Schedule and retention

Set in `.env`:

```ini
BACKUP_CRON="15 3 * * *"
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=6
```

## Offsite storage

A backup on the same disk as the data does not protect against losing the
server. Point restic at object storage:

```ini
RESTIC_REPOSITORY=s3:s3.us-west-004.backblazeb2.com/my-mail-backups
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

## Running on demand

```bash
docker compose run --rm backup backup.sh
docker compose run --rm backup restic snapshots
```

## Restoring

Restore to a scratch directory first and inspect it; never restore straight over
live data.

```bash
docker compose run --rm backup restore.sh latest /backups/restore
```

Rebuild the databases from the dumps:

```bash
docker compose run --rm --entrypoint sh backup -c '
  sqlite3 /backups/restore/main.db      < /backups/restore/tmp/stage/main.db.sql
  sqlite3 /backups/restore/roundcube.db < /backups/restore/tmp/stage/roundcube.db.sql
  sqlite3 /backups/restore/main.db "PRAGMA integrity_check;"
'
```

With `integrity_check` reporting `ok`, stop the stack, copy `mail/`, `dkim/`,
`certs/` and the rebuilt `.db` files into `MAILU_DATA_ROOT`, and start it again.

## Verify the backups actually work

An untested backup is an assumption. Run a restore drill when you first deploy
and after any change to the stack, and confirm the restored message count
matches the live one:

```bash
docker compose exec imap sh -c 'find /mail -type f -name "*,S=*" | wc -l'
```

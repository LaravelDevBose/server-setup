#!/bin/sh
# Nightly encrypted backup of all Mailu state. Run manually with:
#   docker compose run --rm backup backup.sh
set -eu

SRC=/srv/mailu
STAGE=/tmp/stage

restic snapshots >/dev/null 2>&1 || restic init

# SQLite must be dumped, not copied — a live file copy can be torn mid-write.
# The dump runs against a copy because WAL databases (roundcube.db) need to
# create -wal/-shm sidecars, which the read-only source mount forbids.
rm -rf "$STAGE" && mkdir -p "$STAGE"
for db in data/main.db webmail/roundcube.db; do
  [ -f "$SRC/$db" ] || continue
  name=$(basename "$db")
  cp "$SRC/$db" "$STAGE/$name"
  for side in wal shm; do
    if [ -f "$SRC/$db-$side" ]; then cp "$SRC/$db-$side" "$STAGE/$name-$side"; fi
  done
  sqlite3 "$STAGE/$name" .dump > "$STAGE/$name.sql"
  # sqlite3 exits 0 even when .dump aborts, so check the dump actually finished.
  if ! tail -1 "$STAGE/$name.sql" | grep -q '^COMMIT;'; then
    echo "FATAL: dump of $db is incomplete" >&2
    exit 1
  fi
  rm -f "$STAGE/$name" "$STAGE/$name-wal" "$STAGE/$name-shm"
done

restic backup \
  --tag mailu \
  --exclude "$SRC/backups" \
  --exclude "*.db" \
  --exclude "*.db-wal" \
  --exclude "*.db-shm" \
  "$SRC/mail" \
  "$SRC/mailqueue" \
  "$SRC/dkim" \
  "$SRC/certs" \
  "$SRC/data" \
  "$SRC/webmail" \
  "$SRC/filter" \
  "$STAGE"

restic forget --prune \
  --keep-daily "${BACKUP_KEEP_DAILY:-7}" \
  --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
  --keep-monthly "${BACKUP_KEEP_MONTHLY:-6}"

restic check --read-data-subset=1%
rm -rf "$STAGE"
echo "backup: completed $(date -Is)"

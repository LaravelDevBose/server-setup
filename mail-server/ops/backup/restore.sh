#!/bin/sh
# Restore a snapshot to a scratch directory for inspection, then copy back manually.
#   docker compose run --rm backup restore.sh [snapshot-id] [target]
set -eu

SNAPSHOT="${1:-latest}"
TARGET="${2:-/backups/restore}"

mkdir -p "$TARGET"
restic restore "$SNAPSHOT" --target "$TARGET"

echo
echo "Restored to $TARGET (host: \${MAILU_DATA_ROOT}/backups/restore)"
echo "Rebuild SQLite databases from the dumps:"
echo "  sqlite3 main.db     < $TARGET/tmp/stage/main.db.sql"
echo "  sqlite3 roundcube.db < $TARGET/tmp/stage/roundcube.db.sql"
echo
echo "Then, with the stack STOPPED, copy mail/ dkim/ certs/ and the rebuilt .db files"
echo "into \${MAILU_DATA_ROOT} and start it again."

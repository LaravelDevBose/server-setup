#!/bin/sh
set -eu

if [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo "FATAL: RESTIC_PASSWORD is empty. Set it in .env or disable the 'backup' profile." >&2
  exit 1
fi

# One-off invocation: docker compose run --rm backup backup.sh
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

# busybox crond starts jobs with a bare environment, so persist ours for the job to source.
export | sed 's/^export /export /' > /etc/backup.env
chmod 600 /etc/backup.env

echo "${BACKUP_CRON:-15 3 * * *} . /etc/backup.env; /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root

echo "backup: scheduled '${BACKUP_CRON:-15 3 * * *}' -> ${RESTIC_REPOSITORY}"
exec crond -f -l 8

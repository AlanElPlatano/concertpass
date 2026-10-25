#!/usr/bin/env bash
# Usage: scripts/reset-reservations.sh [concert_id]
# Borra las reservas de un concierto (o todas) para repetir una prueba de carga.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_db_password

if [ -n "${1:-}" ]; then
  sql="DELETE FROM reservations WHERE concert_id = '${1//\'/\'\'}';"
else
  sql="DELETE FROM reservations;"
fi

docker run --rm -e PGPASSWORD="$DB_PASSWORD" postgres:16 \
  psql -h "$(db_endpoint)" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$sql"

#!/usr/bin/env bash
# Lists reservations in RDS using psql from a throwaway postgres container.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_db_password

docker run --rm -e PGPASSWORD="$DB_PASSWORD" postgres:16 \
  psql -h "$(db_endpoint)" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT * FROM reservations;"

#!/usr/bin/env bash
# Resume en RDS los boletos por concierto, tipo y estado, para comprobar que
# lo vendido (booked + confirmed) no supera la capacidad.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_db_password

docker run --rm -e PGPASSWORD="$DB_PASSWORD" postgres:16 \
  psql -h "$(db_endpoint)" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT concert_id, ticket_type, status,
             COUNT(*) AS reservas, SUM(quantity) AS boletos
      FROM reservations
      GROUP BY concert_id, ticket_type, status
      ORDER BY concert_id, ticket_type, status;" \
  -c "SELECT concert_id, ticket_type, SUM(quantity) AS boletos_vendidos
      FROM reservations
      WHERE status IN ('booked', 'confirmed')
      GROUP BY concert_id, ticket_type
      ORDER BY concert_id, ticket_type;"

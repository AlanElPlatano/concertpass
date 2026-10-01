#!/usr/bin/env bash
# Runs the published ticket-api image locally, pointing at the RDS instance.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_db_password

image_uri="$(ecr_registry)/ticket-api:latest"

docker rm -f ticket-api >/dev/null 2>&1 || true
docker run -d --name ticket-api -p 8080:8080 \
  -e DB_HOST="$(db_endpoint)" \
  -e DB_PORT="$DB_PORT" \
  -e DB_NAME="$DB_NAME" \
  -e DB_USER="$DB_USER" \
  -e DB_PASSWORD \
  "$image_uri"

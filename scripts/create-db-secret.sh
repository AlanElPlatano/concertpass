#!/usr/bin/env bash
# Guarda las credenciales de RDS en AWS Secrets Manager como JSON con las
# mismas llaves que leen las apps (DB_HOST, DB_PORT, ...). Si el secreto ya
# existe, publica una nueva versión.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_db_password

secret_string=$(cat <<JSON
{"DB_HOST":"$(db_endpoint)","DB_PORT":"${DB_PORT}","DB_NAME":"${DB_NAME}","DB_USER":"${DB_USER}","DB_PASSWORD":"${DB_PASSWORD}"}
JSON
)

if aws secretsmanager describe-secret --region "$AWS_REGION" \
     --secret-id "$DB_SECRET_NAME" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region "$AWS_REGION" \
    --secret-id "$DB_SECRET_NAME" --secret-string "$secret_string" >/dev/null
  echo "Secreto ${DB_SECRET_NAME} actualizado"
else
  aws secretsmanager create-secret --region "$AWS_REGION" \
    --name "$DB_SECRET_NAME" \
    --description "Credenciales de RDS para concertpass" \
    --secret-string "$secret_string" >/dev/null
  echo "Secreto ${DB_SECRET_NAME} creado"
fi

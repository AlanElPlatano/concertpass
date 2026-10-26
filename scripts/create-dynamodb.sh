#!/usr/bin/env bash
# Crea la tabla de eventos en DynamoDB y precarga dos conciertos con
# capacidades diferentes por tipo de boleto (lo que consulta ticket-worker).
#   concert-nicho:        demanda baja, capacidad holgada
#   concert-alta-demanda: capacidad reducida para provocar rechazos
set -euo pipefail
source "$(dirname "$0")/config.sh"

if aws dynamodb describe-table --region "$AWS_REGION" \
     --table-name "$EVENTS_TABLE" >/dev/null 2>&1; then
  echo "La tabla ${EVENTS_TABLE} ya existe, solo se actualizan los conciertos."
else
  aws dynamodb create-table --region "$AWS_REGION" \
    --table-name "$EVENTS_TABLE" \
    --attribute-definitions AttributeName=concert_id,AttributeType=S \
    --key-schema AttributeName=concert_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  echo "Esperando a que la tabla ${EVENTS_TABLE} esté activa..."
  aws dynamodb wait table-exists --region "$AWS_REGION" \
    --table-name "$EVENTS_TABLE"
fi

put_concert() {
  local concert_id="$1" name="$2" date="$3" venue="$4" general="$5" vip="$6"
  aws dynamodb put-item --region "$AWS_REGION" \
    --table-name "$EVENTS_TABLE" \
    --item "{
      \"concert_id\": {\"S\": \"${concert_id}\"},
      \"name\":       {\"S\": \"${name}\"},
      \"date\":       {\"S\": \"${date}\"},
      \"recinto\":    {\"S\": \"${venue}\"},
      \"capacity\":   {\"M\": {
        \"general\": {\"N\": \"${general}\"},
        \"vip\":     {\"N\": \"${vip}\"}
      }}
    }"
  echo "Concierto ${concert_id}: general=${general}, vip=${vip}"
}

put_concert "concert-nicho" "Noche Indie Acústica" \
  "2026-11-20" "Foro Independencia, GDL" 500 50
put_concert "concert-alta-demanda" "Gira Mundial Estelar" \
  "2026-12-05" "Estadio Akron, GDL" 100 10

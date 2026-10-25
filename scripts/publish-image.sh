#!/usr/bin/env bash
# Usage: scripts/publish-image.sh [ticket-checkout|ticket-api|ticket-worker]
# Sin argumentos publica todos los servicios de ECR_REPOSITORIES.
set -euo pipefail
source "$(dirname "$0")/config.sh"

services="${*:-$ECR_REPOSITORIES}"
registry=$(ecr_registry)

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry"

for service in $services; do
  app_dir="$(dirname "$0")/../apps/${service}"
  image_uri="${registry}/${service}:latest"

  aws ecr describe-repositories --region "$AWS_REGION" \
    --repository-names "$service" >/dev/null 2>&1 \
    || aws ecr create-repository --region "$AWS_REGION" \
         --repository-name "$service" >/dev/null

  # Los nodos de EKS son x86_64; se fuerza la plataforma por si se construye en Mac ARM
  docker build --platform linux/amd64 -t "$service" "$app_dir"
  docker tag "$service" "$image_uri"
  docker push "$image_uri"

  echo "Published ${image_uri}"
done

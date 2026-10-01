#!/usr/bin/env bash
# Usage: scripts/publish-image.sh <ticket-checkout|ticket-api>
set -euo pipefail
source "$(dirname "$0")/config.sh"

service="${1:?Usage: $0 <service-name>}"
app_dir="$(dirname "$0")/../apps/${service}"
registry=$(ecr_registry)
image_uri="${registry}/${service}:latest"

aws ecr describe-repositories --region "$AWS_REGION" \
  --repository-names "$service" >/dev/null 2>&1 \
  || aws ecr create-repository --region "$AWS_REGION" \
       --repository-name "$service" >/dev/null

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry"

docker build -t "$service" "$app_dir"
docker tag "$service" "$image_uri"
docker push "$image_uri"

echo "Published ${image_uri}"

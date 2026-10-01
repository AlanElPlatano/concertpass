#!/usr/bin/env bash
# Shared configuration for every script. Override any value via environment.
export AWS_REGION="${AWS_REGION:-us-east-1}"
export DB_INSTANCE_ID="${DB_INSTANCE_ID:-concertpass-db}"
export DB_SECURITY_GROUP="${DB_SECURITY_GROUP:-concertpass-db-sg}"
export DB_NAME="${DB_NAME:-concertpass}"
export DB_USER="${DB_USER:-postgres}"
export DB_PORT="${DB_PORT:-5432}"
export ECR_REPOSITORIES="ticket-checkout ticket-api"

require_db_password() {
  if [ -z "${DB_PASSWORD:-}" ]; then
    echo "DB_PASSWORD is not set. Run: export DB_PASSWORD='<password>'" >&2
    exit 1
  fi
}

ecr_registry() {
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text)
  echo "${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
}

db_endpoint() {
  aws rds describe-db-instances --region "$AWS_REGION" \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query 'DBInstances[0].Endpoint.Address' --output text
}

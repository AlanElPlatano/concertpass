#!/usr/bin/env bash
# Drops the reservations table, ECR repositories, RDS instance, security group, and SQS queue.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_db_password

docker rm -f ticket-api >/dev/null 2>&1 || true

docker run --rm -e PGPASSWORD="$DB_PASSWORD" postgres:16 \
  psql -h "$(db_endpoint)" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "DROP TABLE IF EXISTS reservations;"

for repository in $ECR_REPOSITORIES; do
  aws ecr delete-repository --region "$AWS_REGION" \
    --repository-name "$repository" --force >/dev/null \
    && echo "Deleted ECR repository ${repository}"
done

# Eliminación de RDS y Security Group (ahora se ejecuta siempre)
aws rds delete-db-instance --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --skip-final-snapshot >/dev/null
echo "Waiting for ${DB_INSTANCE_ID} to be deleted..."
aws rds wait db-instance-deleted --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID"
aws ec2 delete-security-group --region "$AWS_REGION" \
  --group-name "$DB_SECURITY_GROUP"
echo "Deleted RDS instance and security group"

# Eliminación de la cola SQS
QUEUE_URL=$(aws sqs get-queue-url --queue-name concertpass-reservations.fifo --region us-east-1 --query QueueUrl --output text 2>/dev/null || true)
if [ -n "$QUEUE_URL" ]; then
  echo "Eliminando cola SQS..."
  aws sqs delete-queue --queue-url "$QUEUE_URL" --region us-east-1
fi
#!/usr/bin/env bash
# Creates a publicly accessible Postgres RDS instance reachable only from
# this machine's public IP on port 5432.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_db_password

DB_INSTANCE_CLASS="db.t3.micro"
DB_STORAGE_GB=20

vpc_id=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

security_group_id=$(aws ec2 create-security-group --region "$AWS_REGION" \
  --group-name "$DB_SECURITY_GROUP" --vpc-id "$vpc_id" \
  --description "Postgres access for concertpass" \
  --query GroupId --output text)

my_ip=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
  --group-id "$security_group_id" --protocol tcp \
  --port "$DB_PORT" --cidr "${my_ip}/32" >/dev/null

aws rds create-db-instance --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --engine postgres \
  --db-instance-class "$DB_INSTANCE_CLASS" \
  --allocated-storage "$DB_STORAGE_GB" \
  --db-name "$DB_NAME" \
  --master-username "$DB_USER" \
  --master-user-password "$DB_PASSWORD" \
  --vpc-security-group-ids "$security_group_id" \
  --publicly-accessible \
  --backup-retention-period 0 \
  --no-multi-az >/dev/null

echo "Waiting for ${DB_INSTANCE_ID} to become available (5-10 min)..."
aws rds wait db-instance-available --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID"

echo "RDS endpoint: $(db_endpoint)"

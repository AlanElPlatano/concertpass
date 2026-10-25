#!/usr/bin/env bash
# Elimina todo lo creado: recursos de k8s, cluster EKS, ECR, RDS y su security
# group, tabla de DynamoDB, secreto de Secrets Manager y cola SQS.
# Cada paso tolera que el recurso ya no exista.
set -uo pipefail
source "$(dirname "$0")/config.sh"

cluster_exists() {
  aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
}

# Primero el namespace, para que se borre el LoadBalancer de ticket-api
if cluster_exists; then
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null
  kubectl delete namespace "$K8S_NAMESPACE" --ignore-not-found --wait=true
fi

docker rm -f ticket-api >/dev/null 2>&1 || true

for repository in $ECR_REPOSITORIES; do
  aws ecr delete-repository --region "$AWS_REGION" \
    --repository-name "$repository" --force >/dev/null 2>&1 \
    && echo "Deleted ECR repository ${repository}"
done

# El security group de RDS se borra antes que el cluster porque tiene una
# regla que referencia al security group del cluster
if aws rds describe-db-instances --region "$AWS_REGION" \
     --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  aws rds delete-db-instance --region "$AWS_REGION" \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --skip-final-snapshot >/dev/null
  echo "Waiting for ${DB_INSTANCE_ID} to be deleted..."
  aws rds wait db-instance-deleted --region "$AWS_REGION" \
    --db-instance-identifier "$DB_INSTANCE_ID"
  echo "Deleted RDS instance"
fi
aws ec2 delete-security-group --region "$AWS_REGION" \
  --group-name "$DB_SECURITY_GROUP" 2>/dev/null \
  && echo "Deleted security group ${DB_SECURITY_GROUP}"

if cluster_exists; then
  echo "Eliminando cluster ${CLUSTER_NAME} (10-15 min)..."
  eksctl delete cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --wait
fi

aws dynamodb delete-table --region "$AWS_REGION" \
  --table-name "$EVENTS_TABLE" >/dev/null 2>&1 \
  && echo "Deleted DynamoDB table ${EVENTS_TABLE}"

aws secretsmanager delete-secret --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_NAME" --force-delete-without-recovery >/dev/null 2>&1 \
  && echo "Deleted secret ${DB_SECRET_NAME}"

QUEUE_URL=$(aws sqs get-queue-url --region "$AWS_REGION" \
  --queue-name "$QUEUE_NAME" --query QueueUrl --output text 2>/dev/null || true)
if [ -n "$QUEUE_URL" ]; then
  aws sqs delete-queue --region "$AWS_REGION" --queue-url "$QUEUE_URL" \
    && echo "Deleted SQS queue ${QUEUE_NAME}"
fi

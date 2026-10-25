#!/usr/bin/env bash
# Crea el cluster de EKS con eksctl en la VPC por defecto (la misma de RDS)
# y permite el tráfico de los nodos hacia Postgres.
# Si existe el rol LabRole (AWS Academy) se usa para el cluster y los nodos,
# porque ahí no se pueden crear roles IAM; si no, eksctl crea los suyos.
set -euo pipefail
source "$(dirname "$0")/config.sh"

LAB_ROLE_ARN="${LAB_ROLE_ARN:-$(aws iam get-role --role-name LabRole \
  --query Role.Arn --output text 2>/dev/null || true)}"

vpc_id=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

# EKS no admite el plano de control en us-east-1e
subnets=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${vpc_id}" Name=default-for-az,Values=true \
  --query 'Subnets[?AvailabilityZone!=`us-east-1e`].[AvailabilityZone,SubnetId]' \
  --output text)

config_file=$(mktemp)
trap 'rm -f "$config_file"' EXIT

{
  cat <<YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
YAML
  if [ -n "$LAB_ROLE_ARN" ]; then
    cat <<YAML
iam:
  serviceRoleARN: ${LAB_ROLE_ARN}
YAML
  fi
  cat <<YAML
vpc:
  id: ${vpc_id}
  subnets:
    public:
YAML
  while read -r az subnet_id; do
    echo "      ${az}: { id: ${subnet_id} }"
  done <<<"$subnets"
  cat <<YAML
managedNodeGroups:
  - name: workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    iam:
YAML
  # Los pods usan el rol del nodo para hablar con SQS y DynamoDB
  if [ -n "$LAB_ROLE_ARN" ]; then
    echo "      instanceRoleARN: ${LAB_ROLE_ARN}"
  else
    cat <<YAML
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/AmazonSQSFullAccess
        - arn:aws:iam::aws:policy/AmazonDynamoDBReadOnlyAccess
YAML
  fi
} >"$config_file"

echo "Creando cluster ${CLUSTER_NAME} (15-20 min)..."
eksctl create cluster -f "$config_file"

cluster_sg=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
  --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
db_sg=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=${DB_SECURITY_GROUP}" \
  --query 'SecurityGroups[0].GroupId' --output text)

if [ "$db_sg" = "None" ]; then
  echo "No existe ${DB_SECURITY_GROUP}; corre create-rds.sh y vuelve a ejecutar este paso." >&2
  exit 1
fi

aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
  --group-id "$db_sg" --protocol tcp --port "$DB_PORT" \
  --source-group "$cluster_sg" >/dev/null \
  && echo "Nodos de EKS autorizados en ${DB_SECURITY_GROUP}"

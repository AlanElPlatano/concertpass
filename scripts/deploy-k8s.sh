#!/usr/bin/env bash
# Despliega los servicios en EKS. Las credenciales de RDS se leen de Secrets
# Manager y se inyectan en los pods como el Secret concertpass-db.
set -euo pipefail
source "$(dirname "$0")/config.sh"
k8s_dir="$(dirname "$0")/../k8s"

kubectl apply -f "${k8s_dir}/namespace.yaml"

env_file=$(mktemp)
trap 'rm -f "$env_file"' EXIT
aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_NAME" --query SecretString --output text \
  | python -c 'import json, sys; [print(f"{k}={v}") for k, v in json.load(sys.stdin).items()]' \
  >"$env_file"
kubectl -n "$K8S_NAMESPACE" create secret generic concertpass-db \
  --from-env-file="$env_file" --dry-run=client -o yaml | kubectl apply -f -

queue_url=$(aws sqs get-queue-url --region "$AWS_REGION" \
  --queue-name "$QUEUE_NAME" --query QueueUrl --output text)
kubectl -n "$K8S_NAMESPACE" create configmap concertpass-config \
  --from-literal=QUEUE_URL="$queue_url" \
  --from-literal=AWS_DEFAULT_REGION="$AWS_REGION" \
  --from-literal=CHECKOUT_URL="http://ticket-checkout:8080/checkout" \
  --dry-run=client -o yaml | kubectl apply -f -

registry=$(ecr_registry)
for manifest in "${k8s_dir}"/ticket-*.yaml; do
  sed "s|ECR_REGISTRY|${registry}|g" "$manifest" | kubectl apply -f -
done

# Fuerza a descargar de nuevo :latest y a releer el Secret/ConfigMap
kubectl -n "$K8S_NAMESPACE" rollout restart deployment
for deployment in ticket-checkout ticket-api ticket-worker; do
  kubectl -n "$K8S_NAMESPACE" rollout status "deployment/${deployment}" --timeout=180s
done

echo "Esperando la URL del LoadBalancer de ticket-api..."
for _ in $(seq 1 30); do
  hostname=$(kubectl -n "$K8S_NAMESPACE" get service ticket-api \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  if [ -n "$hostname" ]; then
    echo "API_URL=http://${hostname}"
    exit 0
  fi
  sleep 10
done
echo "El LoadBalancer aún no tiene hostname; revisa: kubectl -n ${K8S_NAMESPACE} get svc" >&2

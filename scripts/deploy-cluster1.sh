#!/usr/bin/env bash
# Deploy the Puls8 RAG demo stack (Postgres+pgvector, Ollama, Open WebUI) plus the Kasten
# location profile, policy, and PostgreSQL blueprint on cluster1 (the production side of the
# BC/DR demo, StorageClass sc-prod).
#
# Usage: ./scripts/deploy-cluster1.sh [kube-context]
#
# Run from the repository root. Requires: kubectl, helm, a kube-context already pointing at
# cluster1 (or pass it as the first argument).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTEXT="${1:-$(kubectl config current-context)}"
echo "Using kube-context: ${CONTEXT}"
read -r -p "Confirm this is cluster1 (sc-prod side)? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi
KCTL=(kubectl --context "${CONTEXT}")

echo "==> Creating namespace"
"${KCTL[@]}" apply -f manifests/namespace.yaml

echo "==> Postgres credentials"
read -r -p "Postgres username [ai_demo]: " PG_USER
PG_USER="${PG_USER:-ai_demo}"
read -r -p "Postgres database name [ai_demo]: " PG_DB
PG_DB="${PG_DB:-ai_demo}"
read -r -s -p "Postgres password: " PG_PASSWORD
echo
if [[ -z "${PG_PASSWORD}" ]]; then
  echo "A postgres password is required."
  exit 1
fi

"${KCTL[@]}" create secret generic postgres-credentials \
  -n ai-demo \
  --from-literal=POSTGRES_USER="${PG_USER}" \
  --from-literal=POSTGRES_PASSWORD="${PG_PASSWORD}" \
  --from-literal=POSTGRES_DB="${PG_DB}" \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

DB_URL="postgresql://${PG_USER}:${PG_PASSWORD}@postgres.ai-demo.svc.cluster.local:5432/${PG_DB}"
"${KCTL[@]}" create secret generic webui-db-credentials \
  -n ai-demo \
  --from-literal=DATABASE_URL="${DB_URL}" \
  --from-literal=PGVECTOR_DB_URL="${DB_URL}" \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

echo "==> Open WebUI admin account"
read -r -p "Open WebUI admin email: " WEBUI_ADMIN_EMAIL
read -r -s -p "Open WebUI admin password: " WEBUI_ADMIN_PASSWORD
echo
if [[ -z "${WEBUI_ADMIN_EMAIL}" || -z "${WEBUI_ADMIN_PASSWORD}" ]]; then
  echo "Admin email and password are required."
  exit 1
fi

"${KCTL[@]}" create secret generic webui-admin-credentials \
  -n ai-demo \
  --from-literal=WEBUI_ADMIN_EMAIL="${WEBUI_ADMIN_EMAIL}" \
  --from-literal=WEBUI_ADMIN_PASSWORD="${WEBUI_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

echo "==> Deploying Postgres + pgvector"
"${KCTL[@]}" apply -f postgres/pvc.yaml
"${KCTL[@]}" apply -f postgres/deployment.yaml
"${KCTL[@]}" apply -f postgres/service.yaml
"${KCTL[@]}" rollout status deployment/postgres -n ai-demo --timeout=180s

echo "==> Deploying Open WebUI + Ollama via Helm"
helm repo add open-webui https://helm.openwebui.com/ >/dev/null 2>&1 || true
helm repo update open-webui >/dev/null
helm --kube-context "${CONTEXT}" upgrade --install ai-demo open-webui/open-webui \
  -n ai-demo -f charts/values-open-webui-cluster1.yaml --wait --timeout 10m

echo "==> Running init job (model pull + knowledge base upload)"
KB_ARGS=()
for f in kb/*; do
  [[ "$(basename "$f")" == "README.md" ]] && continue
  KB_ARGS+=(--from-file="$f")
done
"${KCTL[@]}" create configmap ai-demo-kb-files -n ai-demo "${KB_ARGS[@]}" \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" create configmap ai-demo-init-script -n ai-demo --from-file=init/init.py \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" delete job ai-demo-init -n ai-demo --ignore-not-found
"${KCTL[@]}" apply -f init/job-init.yaml
"${KCTL[@]}" wait --for=condition=complete job/ai-demo-init -n ai-demo --timeout=1800s

echo "==> Kasten: S3 location profile"
read -r -p "S3 bucket name: " S3_BUCKET
read -r -p "S3 region [us-east-1]: " S3_REGION
S3_REGION="${S3_REGION:-us-east-1}"
read -r -p "S3 endpoint (leave empty for AWS S3): " S3_ENDPOINT
read -r -p "S3 access key id: " S3_ACCESS_KEY
read -r -s -p "S3 secret access key: " S3_SECRET_KEY
echo

"${KCTL[@]}" create secret generic ai-demo-s3-creds \
  -n kasten-io \
  --from-literal=aws_access_key_id="${S3_ACCESS_KEY}" \
  --from-literal=aws_secret_access_key="${S3_SECRET_KEY}" \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

PROFILE_YAML=$(mktemp)
sed \
  -e "s/REPLACE_ME_BUCKET_NAME/${S3_BUCKET}/" \
  -e "s/REPLACE_ME_REGION/${S3_REGION}/" \
  kasten/location-profile.yaml > "${PROFILE_YAML}"
if [[ -n "${S3_ENDPOINT}" ]]; then
  sed -i.bak "s#.*endpoint: .*#      endpoint: ${S3_ENDPOINT}#" "${PROFILE_YAML}"
  rm -f "${PROFILE_YAML}.bak"
fi
"${KCTL[@]}" apply -f "${PROFILE_YAML}"
rm -f "${PROFILE_YAML}"

echo "==> Kasten: policy, blueprint, blueprint binding"
"${KCTL[@]}" apply -f kasten/policy.yaml
"${KCTL[@]}" apply -f kasten/blueprint-postgres.yaml
"${KCTL[@]}" apply -f kasten/blueprintbinding-postgres.yaml

echo "==> Done. ai-demo namespace is up on cluster1, hourly backup+export policy is active."
echo "    Remember to import the ai-demo-s3 profile (or an equivalent one) on cluster2 before the DR demo."

#!/usr/bin/env bash
# Deploy the Puls8 RAG demo stack (Postgres+pgvector, Ollama, Open WebUI) plus the Kasten
# location profile, policy, and PostgreSQL blueprint on cluster1 (the production side of the
# BC/DR demo). Lists available StorageClasses and asks which one to use for the PVCs, so it
# is not tied to a hardcoded sc-prod name.
#
# Usage: ./scripts/deploy-cluster1.sh [kube-context]
#
# Run from the repository root. Requires: kubectl, helm, a kube-context already pointing at
# cluster1 (or pass it as the first argument).

set -euo pipefail

if [[ -t 1 ]]; then
  C_PROMPT=$'\033[1;36m'  # cyan bold, for value prompts
  C_WARN=$'\033[1;33m'    # yellow bold, for yes/no confirmations
  C_RESET=$'\033[0m'
else
  C_PROMPT=""
  C_WARN=""
  C_RESET=""
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTEXT="${1:-$(kubectl config current-context)}"
echo "Using kube-context: ${CONTEXT}"
read -r -p "${C_WARN}Confirm this is cluster1 (sc-prod side)? [y/N] ${C_RESET}" confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi
KCTL=(kubectl --context "${CONTEXT}")

echo "==> Available StorageClasses on ${CONTEXT}"
"${KCTL[@]}" get storageclass
echo
read -r -p "${C_PROMPT}StorageClass to use for the ai-demo PVCs: ${C_RESET}" STORAGE_CLASS
if [[ -z "${STORAGE_CLASS}" ]]; then
  echo "A storage class is required."
  exit 1
fi
if ! "${KCTL[@]}" get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then
  echo "StorageClass '${STORAGE_CLASS}' not found on ${CONTEXT}."
  exit 1
fi

echo "==> Creating namespace"
"${KCTL[@]}" apply -f manifests/namespace.yaml

echo "==> Postgres credentials"
read -r -p "${C_PROMPT}Postgres username [ai_demo]: ${C_RESET}" PG_USER
PG_USER="${PG_USER:-ai_demo}"
read -r -p "${C_PROMPT}Postgres database name [ai_demo]: ${C_RESET}" PG_DB
PG_DB="${PG_DB:-ai_demo}"
read -r -s -p "${C_PROMPT}Postgres password: ${C_RESET}" PG_PASSWORD
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
read -r -p "${C_PROMPT}Open WebUI admin email: ${C_RESET}" WEBUI_ADMIN_EMAIL
read -r -s -p "${C_PROMPT}Open WebUI admin password: ${C_RESET}" WEBUI_ADMIN_PASSWORD
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

echo "==> Deploying Postgres + pgvector (StorageClass: ${STORAGE_CLASS})"
PVC_YAML=$(mktemp)
sed "s/storageClassName: sc-prod/storageClassName: ${STORAGE_CLASS}/" postgres/pvc.yaml > "${PVC_YAML}"
"${KCTL[@]}" apply -f "${PVC_YAML}"
rm -f "${PVC_YAML}"
"${KCTL[@]}" apply -f postgres/deployment.yaml
"${KCTL[@]}" apply -f postgres/service.yaml
"${KCTL[@]}" rollout status deployment/postgres -n ai-demo --timeout=180s

echo "==> How should Open WebUI be exposed for browser access?"
echo "  1) LoadBalancer (MetalLB, or a cloud LB, whatever the cluster provides)"
echo "  2) Ingress via an nginx ingress controller"
echo "  3) Ingress via Traefik"
echo "  4) None, I will handle exposure myself (stays ClusterIP)"
read -r -p "${C_PROMPT}Choice [1-4]: ${C_RESET}" EXPOSE_CHOICE

EXPOSE_ARGS=()
ACCESS_MODE="manual"
INGRESS_HOST=""
case "${EXPOSE_CHOICE}" in
  1)
    ACCESS_MODE="loadbalancer"
    EXPOSE_ARGS+=(--set-string service.type=LoadBalancer)
    ;;
  2|3)
    ACCESS_MODE="ingress"
    INGRESS_CLASS="nginx"
    [[ "${EXPOSE_CHOICE}" == "3" ]] && INGRESS_CLASS="traefik"
    read -r -p "${C_PROMPT}Ingress hostname (must resolve to this cluster's ingress controller): ${C_RESET}" INGRESS_HOST
    if [[ -z "${INGRESS_HOST}" ]]; then
      echo "An ingress hostname is required for this option."
      exit 1
    fi
    EXPOSE_ARGS+=(
      --set ingress.enabled=true
      --set-string ingress.class="${INGRESS_CLASS}"
      --set-string ingress.host="${INGRESS_HOST}"
    )
    ;;
  *)
    ACCESS_MODE="manual"
    echo "Skipping automatic exposure, Open WebUI stays ClusterIP, expose it however you like."
    ;;
esac

echo "==> Deploying Open WebUI + Ollama via Helm (StorageClass: ${STORAGE_CLASS})"
helm repo add open-webui https://helm.openwebui.com/ >/dev/null 2>&1 || true
helm repo update open-webui >/dev/null
helm --kube-context "${CONTEXT}" upgrade --install ai-demo open-webui/open-webui \
  -n ai-demo -f charts/values-open-webui-cluster1.yaml \
  --set-string persistence.storageClass="${STORAGE_CLASS}" \
  --set-string ollama.persistentVolume.storageClass="${STORAGE_CLASS}" \
  "${EXPOSE_ARGS[@]}" \
  --wait --timeout 10m

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
read -r -p "${C_WARN}Create the Kasten Location Profile now via this script? [y/N] ${C_RESET}" CREATE_PROFILE
if [[ "${CREATE_PROFILE}" == "y" || "${CREATE_PROFILE}" == "Y" ]]; then
  read -r -p "${C_PROMPT}S3 bucket name: ${C_RESET}" S3_BUCKET
  read -r -p "${C_PROMPT}S3 region [us-east-1]: ${C_RESET}" S3_REGION
  S3_REGION="${S3_REGION:-us-east-1}"
  read -r -p "${C_PROMPT}S3 endpoint (leave empty for AWS S3): ${C_RESET}" S3_ENDPOINT
  read -r -p "${C_PROMPT}S3 access key id: ${C_RESET}" S3_ACCESS_KEY
  read -r -s -p "${C_PROMPT}S3 secret access key: ${C_RESET}" S3_SECRET_KEY
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
else
  echo "Skipped. Create the ai-demo-s3-creds Secret and apply kasten/location-profile.yaml"
  echo "manually (namespace kasten-io) before the Policy below can export anywhere useful."
fi

echo "==> Kasten: hourly backup + export policy"
"${KCTL[@]}" apply -f kasten/policy.yaml

echo "==> Kasten: PostgreSQL blueprint"
read -r -p "${C_WARN}Create the PostgreSQL Blueprint and BlueprintBinding now via this script? [y/N] ${C_RESET}" CREATE_BLUEPRINT
if [[ "${CREATE_BLUEPRINT}" == "y" || "${CREATE_BLUEPRINT}" == "Y" ]]; then
  "${KCTL[@]}" apply -f kasten/blueprint-postgres.yaml
  "${KCTL[@]}" apply -f kasten/blueprintbinding-postgres.yaml
else
  echo "Skipped. Apply kasten/blueprint-postgres.yaml and kasten/blueprintbinding-postgres.yaml"
  echo "manually, otherwise PostgreSQL falls back to plain (non app-consistent) PVC snapshotting."
fi

echo "==> Kasten: sc-prod-to-sc-dr TransformSet"
read -r -p "${C_WARN}Create the TransformSet now via this script? [y/N] ${C_RESET}" CREATE_TRANSFORMSET
if [[ "${CREATE_TRANSFORMSET}" == "y" || "${CREATE_TRANSFORMSET}" == "Y" ]]; then
  "${KCTL[@]}" apply -f kasten/transformset.yaml
  echo "Note: this TransformSet only takes effect during the DR restore on cluster2,"
  echo "applying it here just stages it, it also needs to exist on cluster2 for demo-dr.sh."
else
  echo "Skipped. Apply kasten/transformset.yaml manually, on cluster2 at minimum (see README)."
fi

echo "==> Done. ai-demo namespace is up on cluster1, hourly backup+export policy is active."
echo "    Remember cluster2 needs the same Location Profile and the TransformSet before the DR demo."

echo
echo "==> Open WebUI access"
case "${ACCESS_MODE}" in
  loadbalancer)
    echo -n "Waiting for a LoadBalancer address"
    LB_ADDR=""
    for _ in $(seq 1 30); do
      LB_ADDR=$("${KCTL[@]}" get svc ai-demo-open-webui -n ai-demo \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
      [[ -n "${LB_ADDR}" ]] && break
      echo -n "."
      sleep 5
    done
    echo
    if [[ -n "${LB_ADDR}" ]]; then
      echo "Open WebUI: http://${LB_ADDR}"
    else
      echo "No address assigned yet, check later with:"
      echo "  kubectl --context ${CONTEXT} -n ai-demo get svc ai-demo-open-webui"
    fi
    ;;
  ingress)
    echo "Open WebUI: http://${INGRESS_HOST}"
    echo "(make sure that hostname actually resolves to this cluster's ingress controller)"
    ;;
  manual)
    echo "Open WebUI has no external access configured. Reach it with:"
    echo "  kubectl --context ${CONTEXT} -n ai-demo port-forward svc/ai-demo-open-webui 8080:80"
    echo "  then open http://localhost:8080"
    ;;
esac

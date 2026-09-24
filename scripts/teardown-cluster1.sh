#!/usr/bin/env bash
# Remove everything scripts/deploy-cluster1.sh installed: the ai-demo namespace and its Helm
# release, and the Kasten policy/blueprint/binding/profile created for the demo.
#
# Usage: ./scripts/teardown-cluster1.sh [kube-context]
# Does NOT delete the S3 bucket contents or the ai-demo-s3-creds secret, since those may still
# be needed by cluster2 for the DR import.

set -euo pipefail

CONTEXT="${1:-$(kubectl config current-context)}"
echo "Using kube-context: ${CONTEXT}"
read -r -p "This deletes the ai-demo namespace and its Helm release on this cluster. Continue? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi
KCTL=(kubectl --context "${CONTEXT}")

echo "==> Removing Kasten policy, blueprint binding, and blueprint"
"${KCTL[@]}" delete -f kasten/policy.yaml --ignore-not-found
"${KCTL[@]}" delete -f kasten/blueprintbinding-postgres.yaml --ignore-not-found
"${KCTL[@]}" delete -f kasten/blueprint-postgres.yaml --ignore-not-found

echo "==> Uninstalling Helm release"
helm --kube-context "${CONTEXT}" uninstall ai-demo -n ai-demo --ignore-not-found || true

echo "==> Deleting ai-demo namespace"
"${KCTL[@]}" delete namespace ai-demo --ignore-not-found

echo "==> Done. Kept the ai-demo-s3 profile and ai-demo-s3-creds secret in kasten-io."
echo "    Delete them manually with:"
echo "      kubectl --context ${CONTEXT} delete profile ai-demo-s3 -n kasten-io"
echo "      kubectl --context ${CONTEXT} delete secret ai-demo-s3-creds -n kasten-io"

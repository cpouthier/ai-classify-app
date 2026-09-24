#!/usr/bin/env bash
# DR demo step: import the latest exported ai-demo restore point on cluster2 and restore it,
# remapping storage from sc-prod to sc-dr via the sc-prod-to-sc-dr TransformSet.
#
# Usage: ./scripts/demo-dr.sh [kube-context]
#
# Prerequisites on cluster2:
#   - Kasten installed in kasten-io
#   - The ai-demo-s3 Profile (kasten/location-profile.yaml) pointing at the SAME bucket/path
#     used by cluster1's hourly export policy
#   - kasten/transformset.yaml applied
#
# NOTE ON ACTION CRD FIELDS: the ImportAction/RestoreAction shapes below reflect Kasten's
# generally documented action pattern (profile-based import, RestorePoint subject +
# transformSets). Field names have shifted slightly across K10 releases, before running this
# against a new environment for the first time, sanity check with:
#   kubectl explain importaction.spec --recursive
#   kubectl explain restoreaction.spec --recursive
# and adjust the two heredocs below if your version differs.

set -euo pipefail

CONTEXT="${1:-$(kubectl config current-context)}"
KCTL=(kubectl --context "${CONTEXT}")

echo "Using kube-context: ${CONTEXT}"
read -r -p "Confirm this is cluster2 (sc-dr side)? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

echo "==> Triggering import from the ai-demo-s3 profile"
IMPORT_NAME=$(cat <<EOF | "${KCTL[@]}" create -f - -o jsonpath='{.metadata.name}'
apiVersion: actions.kio.kasten.io/v1alpha1
kind: ImportAction
metadata:
  generateName: ai-demo-import-
  namespace: kasten-io
spec:
  profile:
    name: ai-demo-s3
    namespace: kasten-io
EOF
)
echo "ImportAction ${IMPORT_NAME} created, waiting for it to complete..."
"${KCTL[@]}" wait --for=jsonpath='{.status.state}'=Complete \
  "importaction/${IMPORT_NAME}" -n kasten-io --timeout=300s

echo "==> Available ai-demo restore points (most recent last):"
"${KCTL[@]}" get restorepoints.apps.kio.kasten.io -n kasten-io \
  -l k10.kasten.io/appNamespace=ai-demo \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp

read -r -p "Restore point name to restore (leave empty for the most recent shown above): " RP_NAME
if [[ -z "${RP_NAME}" ]]; then
  RP_NAME=$("${KCTL[@]}" get restorepoints.apps.kio.kasten.io -n kasten-io \
    -l k10.kasten.io/appNamespace=ai-demo \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}')
fi
if [[ -z "${RP_NAME}" ]]; then
  echo "No restore point found for ai-demo, was the export policy given time to run on cluster1?"
  exit 1
fi
echo "Restoring from: ${RP_NAME}"

RESTORE_YAML=$(mktemp)
cat > "${RESTORE_YAML}" <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  generateName: ai-demo-restore-
  namespace: kasten-io
spec:
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: ${RP_NAME}
    namespace: kasten-io
  transformSets:
    - name: sc-prod-to-sc-dr
      namespace: kasten-io
EOF

echo "==> About to apply:"
cat "${RESTORE_YAML}"
read -r -p "Proceed with restore? [y/N] " go
if [[ "${go}" != "y" && "${go}" != "Y" ]]; then
  echo "Aborted, nothing restored."
  rm -f "${RESTORE_YAML}"
  exit 1
fi

RESTORE_NAME=$("${KCTL[@]}" create -f "${RESTORE_YAML}" -o jsonpath='{.metadata.name}')
rm -f "${RESTORE_YAML}"
echo "RestoreAction ${RESTORE_NAME} created, watching status..."
"${KCTL[@]}" get "restoreaction/${RESTORE_NAME}" -n kasten-io -w

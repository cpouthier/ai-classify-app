#!/usr/bin/env bash
# BC demo step: simulate a worker node failure on cluster1 and watch the ai-demo pods get
# rescheduled thanks to the 30s not-ready/unreachable tolerations set on every pod.
#
# Usage: ./scripts/demo-bc.sh <node-name> [kube-context]
#
# This cordons then drains the node (kubectl-only, works on any cluster regardless of the
# underlying VM/cloud provider). If you want to simulate a harder failure (stopping the VM or
# killing kubelet over SSH) instead of a graceful drain, do that manually after the cordon step
# and skip the drain when prompted, the 30s tolerations will still trigger the reschedule once
# Kubernetes marks the node NotReady/Unreachable.

set -euo pipefail

NODE="${1:?Usage: demo-bc.sh <node-name> [kube-context]}"
CONTEXT="${2:-$(kubectl config current-context)}"
KCTL=(kubectl --context "${CONTEXT}")

echo "Using kube-context: ${CONTEXT}"
echo "==> Pods currently running in ai-demo:"
"${KCTL[@]}" get pods -n ai-demo -o wide

echo "==> Cordoning node ${NODE}"
"${KCTL[@]}" cordon "${NODE}"

read -r -p "Drain ${NODE} now (graceful eviction)? [y/N] " confirm
if [[ "${confirm}" == "y" || "${confirm}" == "Y" ]]; then
  "${KCTL[@]}" drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --force
else
  echo "Skipped drain. If simulating a hard failure, stop the node/kubelet now,"
  echo "pods will reschedule once the node is marked NotReady/Unreachable (30s tolerance)."
fi

echo "==> Watching ai-demo pods reschedule (Ctrl+C to stop watching)"
"${KCTL[@]}" get pods -n ai-demo -o wide --watch

#!/usr/bin/env bash
# Builds and pushes the multi-arch (linux/amd64, linux/arm64) classification app image to
# Docker Hub. Requires `docker buildx` and being logged in (`docker login`).
#
# Usage: ./scripts/build-image.sh [tag]
# Defaults to tag "latest". Pushes to docker.io/cpouthier/ai-image-classify:<tag>.
#
# The arm64 leg cross-compiles torch/torchvision under QEMU emulation during the model-export
# build stage, expect it to take noticeably longer than the amd64 leg.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAG="${1:-latest}"
IMAGE="docker.io/cpouthier/ai-image-classify:${TAG}"

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t "${IMAGE}" \
  --push \
  .

echo "Pushed ${IMAGE}"

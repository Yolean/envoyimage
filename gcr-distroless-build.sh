#!/usr/bin/env bash
# Build the :gcr-distroless-<version> tag — envoy on
# gcr.io/distroless/base-debian13:nonroot. Default is local single-arch
# verify; PUSH=true does a multi-arch reproducible push.
#
#   ./gcr-distroless-build.sh                 # build + smoke-test
#   ENVOY_VERSION=v1.38.0 ./gcr-distroless-build.sh
#   PUSH=true ./gcr-distroless-build.sh       # multi-arch + push

set -eo pipefail
[ -z "$DEBUG" ] || set -x

ENVOY_VERSION="${ENVOY_VERSION:-v1.38.0}"
TARGET="${TARGET:-ghcr.io/yolean/envoy}"
IMAGE_TAG="${IMAGE_TAG:-gcr-distroless-${ENVOY_VERSION}}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64/v8}"
PUSH="${PUSH:-false}"
ADMIN_PORT="${ADMIN_PORT:-19901}"

# Reproducibility — match echo-build.sh.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
REPRO_FLAGS=(--provenance=false --sbom=false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/gcr-distroless"

case "$(uname -m)" in
  x86_64|amd64) HOST_PLATFORM="linux/amd64" ;;
  arm64|aarch64) HOST_PLATFORM="linux/arm64/v8" ;;
  *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

VERIFY_IMAGE="$TARGET:$IMAGE_TAG-verify"
CID=""
cleanup() {
  if [ -n "$CID" ]; then
    docker stop "$CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> building $VERIFY_IMAGE for $HOST_PLATFORM (envoy $ENVOY_VERSION)"
docker buildx build \
  --load \
  --platform "$HOST_PLATFORM" \
  --build-arg ENVOY_VERSION="$ENVOY_VERSION" \
  "${REPRO_FLAGS[@]}" \
  -t "$VERIFY_IMAGE" \
  .

echo "==> running $VERIFY_IMAGE — admin on :$ADMIN_PORT"
# The image inherits envoyproxy/envoy:distroless's default
# /etc/envoy/envoy.yaml. We don't bind the listener port (we don't know
# what's in the default config in every release); only check that the
# admin server comes up and reports ready, which proves the binary
# loads cleanly on the gcr base.
CID=$(docker run -d --rm -p "${ADMIN_PORT}:9901" "$VERIFY_IMAGE")

URL="http://127.0.0.1:${ADMIN_PORT}/ready"
ready=0
for i in $(seq 1 30); do
  if curl -sSf -o /dev/null "$URL"; then
    ready=1
    break
  fi
  if ! docker ps -q --no-trunc | grep -q "$CID"; then
    echo "container exited before admin ready; logs:" >&2
    docker logs "$CID" >&2 || true
    exit 1
  fi
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "admin never reported ready" >&2; exit 1; }

echo "==> /ready response:"
curl -sS "$URL"
echo
echo "==> /server_info envoy version:"
curl -sS "http://127.0.0.1:${ADMIN_PORT}/server_info" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("version =", d.get("version"))' 2>/dev/null || true

docker stop "$CID" >/dev/null
CID=""
echo "==> verification OK"

if [ "$PUSH" != "true" ]; then
  echo "==> PUSH=true not set; skipping multi-arch push"
  exit 0
fi

echo "==> building+pushing $TARGET:$IMAGE_TAG for $PLATFORMS"
docker buildx build \
  --output "type=image,name=$TARGET:$IMAGE_TAG,push=true,rewrite-timestamp=true" \
  --platform "$PLATFORMS" \
  --build-arg ENVOY_VERSION="$ENVOY_VERSION" \
  --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  "${REPRO_FLAGS[@]}" \
  .

echo "==> pushed $TARGET:$IMAGE_TAG"

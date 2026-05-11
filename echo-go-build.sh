#!/usr/bin/env bash
# Build the :echo-go-<version> tag — Go counterpart of the Rust echo
# image. Same verification flow as echo-build.sh.

set -eo pipefail
[ -z "$DEBUG" ] || set -x

ENVOY_VERSION="${ENVOY_VERSION:-v1.38.0}"
TARGET="${TARGET:-ghcr.io/yolean/envoy}"
IMAGE_TAG="${IMAGE_TAG:-echo-go-${ENVOY_VERSION}}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64/v8}"
PUSH="${PUSH:-false}"
HTTP_PORT="${HTTP_PORT:-18080}"

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
REPRO_FLAGS=(--provenance=false --sbom=false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/echo-go"

case "$(uname -m)" in
  x86_64|amd64) HOST_PLATFORM="linux/amd64" ;;
  arm64|aarch64) HOST_PLATFORM="linux/arm64/v8" ;;
  *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

VERIFY_IMAGE="$TARGET:$IMAGE_TAG-verify"
CID=""
cleanup() { [ -n "$CID" ] && docker stop "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> building $VERIFY_IMAGE for $HOST_PLATFORM (envoy $ENVOY_VERSION)"
docker buildx build \
  --load \
  --platform "$HOST_PLATFORM" \
  --build-arg ENVOY_VERSION="$ENVOY_VERSION" \
  "${REPRO_FLAGS[@]}" \
  -t "$VERIFY_IMAGE" \
  .

echo "==> running $VERIFY_IMAGE on :$HTTP_PORT"
CID=$(docker run -d --rm -p "${HTTP_PORT}:8080" "$VERIFY_IMAGE")

URL="http://127.0.0.1:${HTTP_PORT}/q/envoy/echo"
for i in $(seq 1 30); do
  if curl -sSf -o /dev/null --max-time 2 "$URL"; then break; fi
  if ! docker ps -q --no-trunc | grep -q "$CID"; then
    echo "container exited before ready; logs:" >&2
    docker logs "$CID" >&2 || true
    exit 1
  fi
  sleep 1
done

CURL=(curl -sS --max-time 10)

echo "==> verifying GET $URL"
RESP=$("${CURL[@]}" "$URL")
echo "$RESP"
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["request"]["method"]=="GET"; assert d["request"]["real_path"]=="/q/envoy/echo"; assert d["server"]["name"]=="envoy"; assert "headers" in d; assert "hostname" in d'
else
  for k in '"hostname"' '"server"' '"request"' '"headers"' '"real_path": "/q/envoy/echo"' '"method": "GET"'; do
    printf '%s' "$RESP" | grep -q "$k" || { echo "missing $k in response" >&2; exit 1; }
  done
fi

echo "==> verifying HEAD returns 200 without hanging"
HEAD_OUT=$("${CURL[@]}" -I "$URL")
printf '%s\n' "$HEAD_OUT" | grep -qiE '^HTTP/[0-9.]+ 200' || { echo "HEAD: bad status" >&2; exit 1; }

echo "==> verifying POST and arbitrary path also echo"
POST_RESP=$("${CURL[@]}" -X POST -d 'ignored' "http://127.0.0.1:${HTTP_PORT}/foo/bar?x=1")
printf '%s' "$POST_RESP" | grep -q '"method": "POST"' || { echo "POST not echoed" >&2; exit 1; }
printf '%s' "$POST_RESP" | grep -q '"real_path": "/foo/bar"' || { echo "POST path not echoed" >&2; exit 1; }

echo "==> verification OK"
docker stop "$CID" >/dev/null
CID=""

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

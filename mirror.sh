#!/usr/bin/env bash
# Mirror envoyproxy/envoy release tags to ghcr.io/yolean/envoy.
#
# Mirrors both default (vX.Y.Z) and distroless (distroless-vX.Y.Z) tags,
# preserving all upstream architectures (multi-arch index is copied as-is).
#
# Skips tags that already exist at the target.
#
# Required: crane (https://github.com/google/go-containerregistry).
# Login to ghcr.io (and docker.io if rate-limited) before running.

set -eo pipefail
[ -z "$DEBUG" ] || set -x

UPSTREAM="${UPSTREAM:-docker.io/envoyproxy/envoy}"
TARGET="${TARGET:-ghcr.io/yolean/envoy}"
MIN_VERSION="${MIN_VERSION:-1.38.0}"

if ! command -v crane >/dev/null 2>&1; then
  echo "error: crane not found in PATH" >&2
  exit 1
fi

# Returns 0 if $1 >= $2 (semver via sort -V).
ver_ge() {
  [ "$1" = "$2" ] && return 0
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

echo "Listing upstream tags from $UPSTREAM ..."
upstream_tags=$(crane ls "$UPSTREAM")

echo "Listing existing tags at $TARGET ..."
existing_tags=$(crane ls "$TARGET" 2>/dev/null || true)

mirror_one() {
  local tag=$1
  if printf '%s\n' "$existing_tags" | grep -Fxq "$tag"; then
    echo "skip $TARGET:$tag (already mirrored)"
    return 0
  fi
  echo "copy $UPSTREAM:$tag -> $TARGET:$tag"
  crane cp "$UPSTREAM:$tag" "$TARGET:$tag"
}

mirrored=0
considered=0
while IFS= read -r tag; do
  ver=""
  if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    ver="${BASH_REMATCH[1]}"
  elif [[ "$tag" =~ ^distroless-v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    ver="${BASH_REMATCH[1]}"
  else
    continue
  fi
  ver_ge "$ver" "$MIN_VERSION" || continue
  considered=$((considered+1))
  mirror_one "$tag"
  mirrored=$((mirrored+1))
done <<<"$upstream_tags"

echo "done. considered=$considered tags >= v$MIN_VERSION"

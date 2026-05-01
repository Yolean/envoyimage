#!/usr/bin/env bash
# Verify the echo filter rejects invalid filter_config (bad type / unknown
# field / wrong value type) and accepts valid variants. Each case mounts a
# test envoy.yaml into the verify image and runs envoy non-detached; we
# assert exit status and a substring in stderr.

set -eo pipefail
[ -z "$DEBUG" ] || set -x

IMAGE="${IMAGE:-ghcr.io/yolean/envoy:echo-v1.38.0-verify}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

write_config() {
  local name=$1
  local filter_config=$2
  cat > "$TMP/$name.yaml" <<YAML
admin:
  address:
    socket_address: { address: 0.0.0.0, port_value: 9901 }
static_resources:
  listeners:
  - name: main
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          codec_type: AUTO
          route_config:
            name: r
            virtual_hosts:
            - name: d
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                direct_response: { status: 404, body: { inline_string: "x" } }
          http_filters:
          - name: envoy.filters.http.dynamic_modules
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.dynamic_modules.v3.DynamicModuleFilter
              dynamic_module_config:
                name: yolean_envoy_echo
                do_not_close: true
              filter_name: echo
${filter_config}
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
YAML
}

# Cases:
#   name | filter_config snippet (or empty for "no filter_config" case) |
#   should_start (yes/no) | expected substring in logs (optional)
write_config valid_path '              filter_config:
                "@type": type.googleapis.com/google.protobuf.Struct
                value:
                  path: /q/echo'

write_config no_filter_config ''

write_config empty_struct '              filter_config:
                "@type": type.googleapis.com/google.protobuf.Struct
                value: {}'

write_config unknown_field '              filter_config:
                "@type": type.googleapis.com/google.protobuf.Struct
                value:
                  path: /q/echo
                  bogus: yes'

write_config wrong_type '              filter_config:
                "@type": type.googleapis.com/google.protobuf.Struct
                value:
                  path: 123'

write_config wrong_type_array '              filter_config:
                "@type": type.googleapis.com/google.protobuf.Struct
                value:
                  path: ["nope"]'

run_case() {
  local name=$1
  local should_start=$2
  local expect_substr=$3

  echo "=== case: $name (should_start=$should_start) ==="
  # Spawn detached (no --rm so logs survive an early exit); give envoy 4s
  # to either error-exit or come up.
  local cid
  cid=$(docker run -d \
    -v "$TMP/$name.yaml:/etc/envoy/test.yaml:ro" \
    "$IMAGE" -c /etc/envoy/test.yaml)
  sleep 4

  local running=0
  if [ -n "$(docker ps -q --no-trunc --filter id="$cid")" ]; then
    running=1
  fi
  local out
  out=$(docker logs "$cid" 2>&1 || true)
  docker rm -f "$cid" >/dev/null 2>&1 || true

  echo "$out" | tail -3

  case "$should_start" in
    yes)
      if [ "$running" -ne 1 ]; then
        echo "FAIL: $name expected to start but exited" >&2
        return 1
      fi
      ;;
    no)
      if [ "$running" -eq 1 ]; then
        echo "FAIL: $name expected to be rejected but envoy stayed up" >&2
        return 1
      fi
      if [ -n "$expect_substr" ] && ! grep -qF -- "$expect_substr" <<<"$out"; then
        echo "FAIL: $name rejection log missing substring: $expect_substr" >&2
        return 1
      fi
      ;;
  esac
  echo "OK"
}

failures=0
run_case valid_path        yes                                     || failures=$((failures+1))
run_case no_filter_config  yes                                     || failures=$((failures+1))
run_case empty_struct      yes                                     || failures=$((failures+1))
run_case unknown_field     no  "unknown field"                     || failures=$((failures+1))
run_case wrong_type        no  "invalid filter_config"             || failures=$((failures+1))
run_case wrong_type_array  no  "invalid filter_config"             || failures=$((failures+1))

if [ "$failures" -gt 0 ]; then
  echo "=== $failures case(s) failed ==="
  exit 1
fi
echo "=== all cases passed ==="

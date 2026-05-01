# envoyimage

Yolean's envoy image pipeline. Replaces the `envoy-distroless` build that
used to live in `docker-base`.

## What it produces

Two flavors at `ghcr.io/yolean/envoy`:

| Tag                       | Source                                    | Architectures              |
| ------------------------- | ----------------------------------------- | -------------------------- |
| `vX.Y.Z`                  | mirror of `envoyproxy/envoy:vX.Y.Z`       | all upstream archs         |
| `distroless-vX.Y.Z`       | mirror of `envoyproxy/envoy:distroless-vX.Y.Z` | all upstream archs    |
| `echo-vX.Y.Z`             | downstream image with the echo filter     | linux/amd64, linux/arm64/v8 |

Mirroring is a `crane cp` of the upstream multi-arch manifest, so all the
upstream architectures are preserved. Only release tags
(`v\d+\.\d+\.\d+` and `distroless-v\d+\.\d+\.\d+`) at or above
`MIN_VERSION` (default `1.38.0`) are mirrored — no `-latest`, `-dev`,
`-rc` tags, and no backfill of older releases.

## Schedule

`.github/workflows/mirror.yaml` runs daily at **03:01 UTC** plus on demand.
It is independent of any build/verify checks — new upstream releases are
mirrored immediately even if the echo image fails to build.

`.github/workflows/echo.yaml` runs at 03:11 UTC, builds the echo image,
spins it up in docker, verifies `/q/envoy/echo` over HTTP, and only then
pushes the multi-arch manifest.

## Local usage

Both workflows are runnable locally with bash. You need
[crane](https://github.com/google/go-containerregistry) and Docker buildx.

```bash
# Mirror (requires `crane auth login ghcr.io` first)
./mirror.sh

# Build + verify the echo image for the host arch
./echo-build.sh

# Build + push the multi-arch :echo-vX.Y.Z manifest
PUSH=true ./echo-build.sh
```

Override the upstream version with `ENVOY_VERSION=v1.38.0 ./echo-build.sh`.

## The echo filter

`ghcr.io/yolean/envoy:echo-vX.Y.Z` bundles a Rust dynamic-modules filter
that intercepts a configurable path (default `/q/envoy/echo`) and returns
a pretty-printed JSON document equivalent in spirit to the plain-text
response from `registry.k8s.io/echoserver`:

```json
{
  "hostname": "...",
  "server": { "name": "envoy", "version": "v1.38.0" },
  "request": {
    "method": "GET",
    "path": "/q/envoy/echo?foo=bar",
    "real_path": "/q/envoy/echo",
    "query": "foo=bar",
    "scheme": "http",
    "authority": "localhost:8080",
    "request_uri": "http://localhost:8080/q/envoy/echo?foo=bar",
    "client_address": "127.0.0.1:54321",
    "protocol": "HTTP/1.1"
  },
  "headers": {
    "user-agent": ["curl/8.4.0"],
    "accept":     ["*/*"]
  }
}
```

The image ships with `envoy.yaml` wiring the filter at `:8080` and admin
at `:9901`, with a 404 catchall for everything else. To use the filter
inside your own envoy bootstrap, add it to your HTTP filter chain *before*
`envoy.filters.http.router`:

```yaml
http_filters:
- name: envoy.filters.http.dynamic_modules
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.dynamic_modules.v3.DynamicModuleFilter
    dynamic_module_config:
      name: yolean_envoy_echo
      do_not_close: true
    filter_name: echo
    filter_config:
      "@type": type.googleapis.com/google.protobuf.Struct
      value:
        path: /q/envoy/echo
- name: envoy.filters.http.router
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

The module file `libyolean_envoy_echo.so` is at `/etc/envoy/`. Either set
`ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/etc/envoy` (already set in the image)
or copy the `.so` to a directory on that path in your derived image.

## New envoy releases

No human in the loop. The scheduled `echo` workflow lists every upstream
`envoyproxy/envoy:vX.Y.Z` at or above `MIN_VERSION` and builds whichever
ones don't yet have a corresponding `:echo-vX.Y.Z` at
`ghcr.io/yolean/envoy`. The Rust SDK git tag in `Cargo.toml` is rewritten
inside the Dockerfile to match the build target, so a single
`ENVOY_VERSION` value drives both the runtime image and the SDK pin.

To force a specific version, use the workflow's `workflow_dispatch`
input. To pre-emptively bump the local default for PR/push builds, edit
the `ARG ENVOY_VERSION=` line in `echo/Dockerfile` and the matching
default in `echo-build.sh`.

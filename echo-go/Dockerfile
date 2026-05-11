# syntax=docker/dockerfile:1.7
ARG ENVOY_VERSION=v1.38.0

FROM --platform=$TARGETPLATFORM golang:1.25-trixie@sha256:3965b9511a9bed199f0b4eb146f99c31971a5c0adb3240d9f25e233cbd9e01c8 AS builder
ARG ENVOY_VERSION
ENV ENVOY_VERSION=${ENVOY_VERSION}
# CGO needs a C compiler at build time; trixie's gcc is already present
# in golang:trixie, but include git for `go get` against a commit SHA.
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY go.mod go.sum ./
COPY main.go echo.go ./
# Pin the Go SDK to the commit that ships with this envoy release.
# We resolve the envoy tag to a commit SHA via git ls-remote, then
# `go get` against that SHA so go.mod/go.sum reflect the matching
# dynamic_modules SDK build.
RUN --mount=type=cache,target=/root/go,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    set -eu && \
    ENVOY_SHA=$(git ls-remote https://github.com/envoyproxy/envoy "refs/tags/${ENVOY_VERSION}" | awk '{print $1}') && \
    test -n "$ENVOY_SHA" && \
    go get "github.com/envoyproxy/envoy/source/extensions/dynamic_modules@${ENVOY_SHA}" && \
    CGO_ENABLED=1 go build -buildmode=c-shared \
      -ldflags "-X main.envoyVersion=${ENVOY_VERSION}" \
      -o /libyolean_envoy_echo_go.so . && \
    cp /usr/lib/*-linux-gnu/libgcc_s.so.1 /libgcc_s.so.1

FROM --platform=$TARGETPLATFORM envoyproxy/envoy:distroless-${ENVOY_VERSION}
COPY --from=builder /libyolean_envoy_echo_go.so /etc/envoy/libyolean_envoy_echo_go.so
COPY --from=builder /libgcc_s.so.1 /lib/libgcc_s.so.1
COPY envoy.yaml /etc/envoy/envoy.yaml

ENV ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/etc/envoy
# Go cgo's stricter pointer check panics on startup because the SDK
# hands Go-allocated config/filter objects to envoy across the C ABI
# without runtime.Pinner. Disable cgocheck — same workaround the
# upstream example relies on.
ENV GODEBUG=cgocheck=0
EXPOSE 8080 9901
ENTRYPOINT ["/usr/local/bin/envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml"]

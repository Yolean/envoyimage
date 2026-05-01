# syntax=docker/dockerfile:1.7
#
# Successor to https://github.com/Yolean/docker-base/tree/main/envoy-distroless.
# Lays the envoy binary + /etc/envoy from the upstream distroless envoy
# image on top of gcr.io/distroless/base-debian13:nonroot — same shape
# as docker-base used to ship, but driven by ENVOY_VERSION so the same
# pipeline that mirrors and builds :echo-* can build :gcr-distroless-*
# tags for every release.
ARG ENVOY_VERSION=v1.38.0

FROM --platform=$TARGETPLATFORM envoyproxy/envoy:distroless-${ENVOY_VERSION} AS envoy

FROM --platform=$TARGETPLATFORM gcr.io/distroless/base-debian13:nonroot@sha256:fb282f8ed3057f71dbfe3ea0f5fa7e961415dafe4761c23948a9d4628c6166fe

COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=envoy /etc/envoy/ /etc/envoy/

ENTRYPOINT ["/usr/local/bin/envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml"]

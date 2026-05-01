# syntax=docker/dockerfile:1.7
ARG ENVOY_VERSION=v1.38.0

# Build the dynamic module .so for the target architecture. Using
# --platform=$TARGETPLATFORM keeps the build native per-arch (works under
# QEMU on amd64 runners and natively on arm64 runners) and avoids the
# cross-toolchain rabbit hole.
FROM --platform=$TARGETPLATFORM rust:trixie@sha256:a9cfb755b33f5bb872610cbdb25da61f527416b28fc9c052bbce4bef93e7799a AS builder
ARG ENVOY_VERSION
ENV ENVOY_VERSION=${ENVOY_VERSION}
# bindgen (transitive build-dep of the SDK) needs libclang at compile time.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libclang-dev clang && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY .cargo .cargo
COPY src ./src
# Sync the Rust SDK git tag with the target envoy version so a single
# ENVOY_VERSION arg drives both the SDK and the runtime image. When the
# rewrite changes the tag, drop the SDK lockfile entry so cargo
# re-resolves only that crate; the rest stays pinned for reproducibility.
RUN orig=$(grep -oE 'tag = "v[0-9]+\.[0-9]+\.[0-9]+"' Cargo.toml | head -1) && \
    sed -i -E "s|tag = \"v[0-9]+\\.[0-9]+\\.[0-9]+\"|tag = \"${ENVOY_VERSION}\"|" Cargo.toml && \
    new=$(grep -oE 'tag = "v[0-9]+\.[0-9]+\.[0-9]+"' Cargo.toml | head -1) && \
    if [ "$orig" != "$new" ]; then \
      cargo update -p envoy-proxy-dynamic-modules-rust-sdk; \
      LOCKED_FLAG=""; \
    else \
      LOCKED_FLAG="--locked"; \
    fi && \
    echo "LOCKED_FLAG=$LOCKED_FLAG" > /tmp/lockflag.env
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target,sharing=locked \
    . /tmp/lockflag.env && \
    cargo build --release $LOCKED_FLAG && \
    cp target/release/libyolean_envoy_echo.so /libyolean_envoy_echo.so && \
    cp /usr/lib/*-linux-gnu/libgcc_s.so.1 /libgcc_s.so.1

FROM --platform=$TARGETPLATFORM envoyproxy/envoy:distroless-${ENVOY_VERSION}
COPY --from=builder /libyolean_envoy_echo.so /etc/envoy/libyolean_envoy_echo.so
# distroless envoy doesn't ship libgcc_s.so.1 but Rust's precompiled stdlib
# still references _Unwind_* even with panic=abort. Bring it from the
# matching debian builder so the .so resolves at dlopen time.
COPY --from=builder /libgcc_s.so.1 /lib/libgcc_s.so.1
COPY envoy.yaml /etc/envoy/envoy.yaml

# The dynamic_modules filter resolves the module by name relative to
# ENVOY_DYNAMIC_MODULES_SEARCH_PATH.
ENV ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/etc/envoy

EXPOSE 8080 9901
ENTRYPOINT ["/usr/local/bin/envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml"]

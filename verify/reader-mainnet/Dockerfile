# paykit-reader-demo built from the same pinned upstream revisions as the
# deployed Paykit Server, with one verification patch: the upstream binary is
# hardcoded to the local Pubky testnet (configured_testnet_pubky), which cannot
# resolve identities on the real network. Setting
# PAYKIT_READER_PUBKY_TESTNET_HOST=mainnet selects the Pubky SDK's default
# mainnet client instead (the same construction paykit-server uses for
# [paykit] network = "mainnet"), so the reader can receive the private
# Payment Request from the deployed rails with staging-homeserver identities.
FROM rust:1.91.1-slim-bookworm@sha256:8514999d4786ef12efe89239e86b3d0a021b94b9d35108c8efe6c79ca7dc1a65 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*

ARG PAYKIT_SERVER_REV=f38c7915e6b9b104e040773e78438f8aa984c46c
ARG PAYKIT_RS_REV=52a852995bfc457b78d32f5a45f6741766a89bba
ARG LOCKS_DEP_REV=df5ea1b6d8dcdec3a9b5a915c3f57bca69d75c8a

WORKDIR /build
RUN set -eu; \
    git clone https://github.com/pubky/paykit-rs.git /tmp/paykit-rs; \
    git -C /tmp/paykit-rs checkout --detach "$PAYKIT_RS_REV"; \
    test "$(git -C /tmp/paykit-rs rev-parse HEAD)" = "$PAYKIT_RS_REV"; \
    mkdir -p /build/paykit-rs; \
    cp -a /tmp/paykit-rs/paykit-lib /build/paykit-rs/paykit-lib; \
    cp -a /tmp/paykit-rs/paykit-sdk /build/paykit-rs/paykit-sdk; \
    rm -rf /tmp/paykit-rs; \
    git clone https://github.com/pubky/locks.git /tmp/locks; \
    git -C /tmp/locks checkout --detach "$LOCKS_DEP_REV"; \
    test "$(git -C /tmp/locks rev-parse HEAD)" = "$LOCKS_DEP_REV"; \
    mkdir -p /build/locks; \
    cp /tmp/locks/Cargo.toml /tmp/locks/Cargo.lock /build/locks/; \
    cp -a /tmp/locks/locks-core /tmp/locks/locks-service /tmp/locks/locks-server \
        /tmp/locks/locks-sdk /tmp/locks/locks-e2e /build/locks/; \
    rm -rf /tmp/locks; \
    git clone https://github.com/pubky/paykit-server.git /build/paykit-server; \
    git -C /build/paykit-server checkout --detach "$PAYKIT_SERVER_REV"; \
    test "$(git -C /build/paykit-server rev-parse HEAD)" = "$PAYKIT_SERVER_REV"

WORKDIR /build/paykit-server
RUN sh scripts/prepare-local-docker-sources.sh

# Mainnet patch: recognize the sentinel host "mainnet" and build the default
# (mainnet) Pubky client. Fails the build if the anchor line drifts.
COPY apply-mainnet-patch.sh /tmp/apply-mainnet-patch.sh
RUN sh /tmp/apply-mainnet-patch.sh paykit-server/src/bin/paykit-reader-demo.rs

RUN cargo build --locked --release -p paykit-server --bin paykit-reader-demo && \
    install -Dm755 target/release/paykit-reader-demo /out/paykit-reader-demo

FROM debian:bookworm-20260112-slim@sha256:56ff6d36d4eb3db13a741b342ec466f121480b5edded42e4b7ee850ce7a418ee AS runtime
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/paykit-reader-demo /usr/local/bin/paykit-reader-demo
ENTRYPOINT ["/usr/local/bin/paykit-reader-demo"]

# Paykit Server built from the pinned upstream revisions verified end to end
# in the local payments-env stack:
#   pubky/paykit-server @ f38c7915  (runtime)
#   pubky/paykit-rs     @ 52a85299  (the exact rev pinned in paykit-server's manifests)
#   pubky/locks         @ df5ea1b6  (the exact locks-core rev pinned in paykit-server's manifests)
#
# This mirrors the upstream Dockerfile.local (same base image digests, same
# /build layout, same fail-closed prepare-local-docker-sources.sh step) but
# clones the pinned sources at build time instead of using named BuildKit
# contexts, which Railway's builder does not support.
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

# Fail-closed: rewrites the git dependency pins to the local paths above and
# aborts if the supplied trees drift from the committed manifest pins.
RUN sh scripts/prepare-local-docker-sources.sh

RUN cargo build --locked --release -p paykit-server --bins && \
    install -Dm755 target/release/paykit-server /out/paykit-server && \
    install -Dm755 target/release/paykit-companion-auth /out/paykit-companion-auth && \
    install -Dm755 target/release/paykit-reader-demo /out/paykit-reader-demo

FROM debian:bookworm-20260112-slim@sha256:56ff6d36d4eb3db13a741b342ec466f121480b5edded42e4b7ee850ce7a418ee AS runtime

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

RUN groupadd --system --gid 10001 paykit && \
    useradd --system --uid 10001 --gid paykit --create-home --home-dir /home/paykit paykit

COPY --from=builder /out/paykit-server /usr/local/bin/paykit-server
COPY --from=builder /out/paykit-companion-auth /usr/local/bin/paykit-companion-auth
COPY --from=builder /out/paykit-reader-demo /usr/local/bin/paykit-reader-demo
COPY entrypoint.sh /usr/local/bin/rails-entrypoint.sh
RUN chmod +x /usr/local/bin/rails-entrypoint.sh

USER paykit:paykit
WORKDIR /home/paykit
EXPOSE 3001
ENTRYPOINT ["/usr/local/bin/rails-entrypoint.sh"]

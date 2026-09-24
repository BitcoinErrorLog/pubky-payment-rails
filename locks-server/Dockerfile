# Lock Server built from the pinned BitcoinErrorLog/locks revision (master
# merge of #1, Bitkit grant connect beside the Ring cookie QR). The fork is
# pubky/locks plus that change; the build stage mirrors the fork's own
# Dockerfile at that revision. The source is cloned at build time and pinned
# fail-closed. Base images are pinned by index digest (resolved 2026-09-24); the
# apk packages still come from the Alpine 3.20 repositories at build time.
FROM rust:1.91.1-alpine3.20@sha256:1f1428db130caff5a0ae90d268a9dda7ba5fd6dad69792ab23483a31f11c1338 AS builder

# The repository's rust-toolchain.toml also asks rustup for clippy, rustfmt and
# the wasm target; the image's 1.91.1 toolchain is all the server build needs.
ENV RUSTUP_TOOLCHAIN=1.91.1

RUN apk add --no-cache \
    musl-dev \
    openssl-dev \
    openssl-libs-static \
    pkgconfig \
    build-base \
    cmake \
    perl \
    curl \
    git

ENV OPENSSL_STATIC=yes
ENV OPENSSL_LIB_DIR=/usr/lib
ENV OPENSSL_INCLUDE_DIR=/usr/include
ENV SQLX_OFFLINE=true

ARG LOCKS_REPO=https://github.com/BitcoinErrorLog/locks.git
ARG LOCKS_REV=c489b59eaa19ef905aa2070f6f98c3a54a426583

WORKDIR /usr/src/app
RUN git clone "$LOCKS_REPO" . \
    && git checkout --detach "$LOCKS_REV" \
    && test "$(git rev-parse HEAD)" = "$LOCKS_REV"

RUN cargo build --release -p locks-server --bin locks-server \
    && strip target/release/locks-server

FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

ARG LOCKS_REPO=https://github.com/BitcoinErrorLog/locks.git
ARG LOCKS_REV=c489b59eaa19ef905aa2070f6f98c3a54a426583
LABEL org.opencontainers.image.title="Lock Server (Railway rails)" \
      org.opencontainers.image.source="https://github.com/BitcoinErrorLog/pubky-payment-rails" \
      io.pubky.locks.repository="$LOCKS_REPO" \
      io.pubky.locks.revision="$LOCKS_REV"

RUN apk add --no-cache ca-certificates

COPY --from=builder /usr/src/app/target/release/locks-server /usr/local/bin/locks-server
COPY entrypoint.sh /usr/local/bin/rails-entrypoint.sh
RUN chmod +x /usr/local/bin/rails-entrypoint.sh

ENV HOME=/var/lib/pubky-lock
WORKDIR /var/lib/pubky-lock

EXPOSE 3000

CMD ["/usr/local/bin/rails-entrypoint.sh"]

# Lock Server built from the pinned upstream revision (pubky/locks @ ba49a777),
# the same revision verified end to end in the local payments-env stack.
# Build stage mirrors the upstream Dockerfile at that revision; the source is
# cloned at build time and pinned fail-closed.
FROM rust:1.89.0-alpine3.20 AS builder

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

ARG LOCKS_REV=ba49a777a94db318ec6ebd427315080a5b904645

WORKDIR /usr/src/app
RUN git clone https://github.com/pubky/locks.git . \
    && git checkout --detach "$LOCKS_REV" \
    && test "$(git rev-parse HEAD)" = "$LOCKS_REV"

RUN cargo build --release -p locks-server --bin locks-server \
    && strip target/release/locks-server

FROM alpine:3.20

RUN apk add --no-cache ca-certificates

COPY --from=builder /usr/src/app/target/release/locks-server /usr/local/bin/locks-server
COPY entrypoint.sh /usr/local/bin/rails-entrypoint.sh
RUN chmod +x /usr/local/bin/rails-entrypoint.sh

ENV HOME=/var/lib/pubky-lock
WORKDIR /var/lib/pubky-lock

EXPOSE 3000

CMD ["/usr/local/bin/rails-entrypoint.sh"]

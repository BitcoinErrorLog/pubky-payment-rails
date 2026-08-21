#!/bin/sh
# Generates fulcrum.conf from environment and starts Fulcrum.
# Binds the Electrum TCP listener on the IPv6 wildcard (dual-stack) because
# both Railway private networking (paykit-server -> fulcrum) and Railway TCP
# proxies (public Bitkit access) connect over IPv6.
set -eu

: "${BITCOIND_RPC_HOST:?BITCOIND_RPC_HOST is required}"
: "${BITCOIND_RPC_USER:?BITCOIND_RPC_USER is required}"
: "${BITCOIND_RPC_PASS:?BITCOIND_RPC_PASS is required}"
TCP_BIND="${FULCRUM_TCP_BIND:-:::50001}"

mkdir -p /data

cat > /tmp/fulcrum.conf <<EOF
datadir = /data
bitcoind = ${BITCOIND_RPC_HOST}:18443
rpcuser = ${BITCOIND_RPC_USER}
rpcpassword = ${BITCOIND_RPC_PASS}
tcp = ${TCP_BIND}
peering = false
announce = false
EOF

exec Fulcrum /tmp/fulcrum.conf

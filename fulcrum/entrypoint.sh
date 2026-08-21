#!/bin/sh
# Generates fulcrum.conf from environment and starts Fulcrum.
# Binds the Electrum TCP listener on the IPv6 wildcard (dual-stack) because
# both Railway private networking (paykit-server -> fulcrum) and Railway TCP
# proxies (public Bitkit access) connect over IPv6.
set -eu

: "${BITCOIND_RPC_HOST:?BITCOIND_RPC_HOST is required}"
: "${BITCOIND_RPC_USER:?BITCOIND_RPC_USER is required}"
: "${BITCOIND_RPC_PASS:?BITCOIND_RPC_PASS is required}"
mkdir -p /data

# Two listeners: Qt treats "::" as IPv6-only, so the IPv4 wildcard is bound
# separately - Railway's public TCP proxy connects over IPv4 private
# networking while paykit-server connects over IPv6 (fulcrum.railway.internal).
cat > /tmp/fulcrum.conf <<EOF
datadir = /data
bitcoind = ${BITCOIND_RPC_HOST}:18443
rpcuser = ${BITCOIND_RPC_USER}
rpcpassword = ${BITCOIND_RPC_PASS}
tcp = 0.0.0.0:50001
tcp = :::50001
peering = false
announce = false
EOF

exec Fulcrum /tmp/fulcrum.conf

#!/bin/sh
# Regtest-only bitcoind. RPC binds both IPv4 and IPv6 wildcards because
# Railway private networking is IPv6 (fulcrum/miner reach us via
# bitcoind.railway.internal). REGTEST ONLY - never configure mainnet here.
set -eu

: "${BITCOIND_RPC_USER:?BITCOIND_RPC_USER is required}"
: "${BITCOIND_RPC_PASS:?BITCOIND_RPC_PASS is required}"

mkdir -p /data

exec bitcoind \
  -regtest=1 \
  -datadir=/data \
  -server=1 \
  -txindex=1 \
  -rpcbind=0.0.0.0 \
  -rpcbind=:: \
  -rpcallowip=0.0.0.0/0 \
  -rpcallowip=::/0 \
  -rpcuser="$BITCOIND_RPC_USER" \
  -rpcpassword="$BITCOIND_RPC_PASS" \
  -fallbackfee=0.0001

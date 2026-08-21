#!/bin/sh
# Regtest-only bitcoind plus the block-generation loop.
#
# RPC binds both IPv4 and IPv6 wildcards because Railway private networking is
# IPv6 (fulcrum reaches us via bitcoind.railway.internal). The miner loop runs
# in this container over 127.0.0.1 because the bitcoin-cli build in this image
# cannot open IPv6 client connections (libevent limitation, verified against
# both ::1 and the private domain), so a separate sidecar service cannot reach
# the node. REGTEST ONLY - never configure mainnet here.
set -eu

: "${BITCOIND_RPC_USER:?BITCOIND_RPC_USER is required}"
: "${BITCOIND_RPC_PASS:?BITCOIND_RPC_PASS is required}"
MINE_INTERVAL="${MINE_INTERVAL_SECONDS:-45}"

mkdir -p /data

bitcoind \
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
  -fallbackfee=0.0001 &
BITCOIND_PID=$!

bcli() {
  bitcoin-cli -regtest -rpcconnect=127.0.0.1 -rpcport=18443 \
    -rpcuser="$BITCOIND_RPC_USER" -rpcpassword="$BITCOIND_RPC_PASS" "$@"
}

(
  echo "[miner] waiting for bitcoind RPC"
  until bcli getblockchaininfo >/dev/null 2>&1; do sleep 2; done

  bcli createwallet miner >/dev/null 2>&1 || bcli loadwallet miner >/dev/null 2>&1 || true
  ADDR="$(bcli -rpcwallet=miner getnewaddress | tr -d '\r\n')"
  echo "[miner] mining to $ADDR every ${MINE_INTERVAL}s"

  HEIGHT="$(bcli getblockcount | tr -d '\r\n')"
  if [ "$HEIGHT" -lt 101 ]; then
    echo "[miner] bootstrapping chain: mining $((101 - HEIGHT)) blocks for coin maturity"
    bcli -rpcwallet=miner generatetoaddress "$((101 - HEIGHT))" "$ADDR" >/dev/null
  fi

  while :; do
    bcli -rpcwallet=miner generatetoaddress 1 "$ADDR" >/dev/null 2>&1 \
      || echo "[miner] block generation failed; retrying next interval"
    sleep "$MINE_INTERVAL"
  done
) &

wait "$BITCOIND_PID"

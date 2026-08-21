#!/bin/sh
# Ensures the regtest chain has mature coins (101+ blocks) and then mines one
# block every MINE_INTERVAL_SECONDS (default 45) to a node-held miner wallet
# address, so on-chain payments reach confirmed/finality without manual mining.
set -eu

: "${BITCOIND_RPC_HOST:?BITCOIND_RPC_HOST is required}"
: "${BITCOIND_RPC_USER:?BITCOIND_RPC_USER is required}"
: "${BITCOIND_RPC_PASS:?BITCOIND_RPC_PASS is required}"
INTERVAL="${MINE_INTERVAL_SECONDS:-45}"

bcli() {
  bitcoin-cli -regtest \
    -rpcconnect="$BITCOIND_RPC_HOST" -rpcport=18443 \
    -rpcuser="$BITCOIND_RPC_USER" -rpcpassword="$BITCOIND_RPC_PASS" \
    "$@"
}

echo "[miner] waiting for bitcoind at $BITCOIND_RPC_HOST:18443"
until bcli getblockchaininfo >/dev/null 2>&1; do sleep 2; done

bcli createwallet miner >/dev/null 2>&1 || bcli loadwallet miner >/dev/null 2>&1 || true
ADDR="$(bcli -rpcwallet=miner getnewaddress | tr -d '\r\n')"
echo "[miner] mining to $ADDR"

HEIGHT="$(bcli getblockcount | tr -d '\r\n')"
if [ "$HEIGHT" -lt 101 ]; then
  echo "[miner] bootstrapping chain: mining $((101 - HEIGHT)) blocks for coin maturity"
  bcli -rpcwallet=miner generatetoaddress "$((101 - HEIGHT))" "$ADDR" >/dev/null
fi

while :; do
  bcli -rpcwallet=miner generatetoaddress 1 "$ADDR" >/dev/null 2>&1 \
    || echo "[miner] block generation failed; retrying next interval"
  sleep "$INTERVAL"
done

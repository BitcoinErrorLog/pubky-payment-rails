# Miner sidecar: keeps regtest blocks flowing so payments confirm without
# babysitting. Same pinned Bitcoin Core image as the node (for bitcoin-cli).
FROM bitcoin/bitcoin:29.1@sha256:de62c536feb629bed65395f63afd02e3a7a777a3ec82fbed773d50336a739319

USER root
COPY mine-loop.sh /usr/local/bin/mine-loop.sh
RUN chmod +x /usr/local/bin/mine-loop.sh

ENTRYPOINT ["/usr/local/bin/mine-loop.sh"]

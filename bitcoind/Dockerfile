# Bitcoin Core regtest node for the Pubky marketplace staging payment rails.
# Pinned to the exact image digest verified in the local payments-env stack.
FROM bitcoin/bitcoin:29.1@sha256:de62c536feb629bed65395f63afd02e3a7a777a3ec82fbed773d50336a739319

USER root
COPY entrypoint.sh /usr/local/bin/rails-entrypoint.sh
RUN chmod +x /usr/local/bin/rails-entrypoint.sh

# Chain state lives on a Railway volume mounted at /data.
ENTRYPOINT ["/usr/local/bin/rails-entrypoint.sh"]

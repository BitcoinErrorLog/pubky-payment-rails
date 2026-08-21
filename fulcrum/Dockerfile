# Fulcrum Electrum server indexing the regtest node. Pinned to the exact
# image digest verified in the local payments-env stack.
FROM cculianu/fulcrum:v2.0.0@sha256:cb1c006d0cff104696f4791d0f1516699b2c163120165461385e4de206271943

USER root
COPY entrypoint.sh /usr/local/bin/rails-entrypoint.sh
RUN chmod +x /usr/local/bin/rails-entrypoint.sh

# Index data lives on a Railway volume mounted at /data.
ENTRYPOINT ["/usr/local/bin/rails-entrypoint.sh"]

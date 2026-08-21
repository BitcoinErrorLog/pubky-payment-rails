#!/bin/sh
# Inserts a mainnet branch into paykit-reader-demo's configured_testnet_pubky.
# When PAYKIT_READER_PUBKY_TESTNET_HOST=mainnet, the reader uses the Pubky
# SDK's default mainnet client (same as paykit-server's network = "mainnet").
# Fail-closed: aborts unless the anchor exists and the insertion is verified.
set -eu

file="$1"

grep -q 'fn configured_testnet_pubky(host: &str) -> Result<Pubky, Failure> {' "$file" \
  || { echo "anchor line not found in $file" >&2; exit 1; }
grep -q 'host == "mainnet"' "$file" && { echo "patch already applied" >&2; exit 1; }

awk '
  { print }
  /fn configured_testnet_pubky\(host: &str\) -> Result<Pubky, Failure> \{/ {
    print "    if host == \"mainnet\" {"
    print "        return Pubky::new().map_err(|_| Failure::InvalidConfig);"
    print "    }"
  }
' "$file" > "$file.patched"
mv "$file.patched" "$file"

grep -q 'host == "mainnet"' "$file" || { echo "patch failed to apply" >&2; exit 1; }
echo "mainnet patch applied to $file"

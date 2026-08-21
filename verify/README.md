# Verification driver

A standalone Node driver that exercises the DEPLOYED rails over public HTTPS
with throwaway real-network identities. See the repo README "Consumers" and
the deployment notes for how it was used. It depends on `@synonymdev/pubky`
(resolve it against any checkout that has it installed, e.g. pubky-app).

Subcommands: gen, signup, identities, connect, setup-start, setup-claim,
setup-poll, reader-marker, publish, negative, proof, status, lifecycle,
credential, checkout.

## Fiat locks (fiat-verifier gateway)

`publish` takes `ASSET`/`AMOUNT` env overrides: `ASSET=USD AMOUNT=1999` authors
a `{amount: "1999", asset: "USD"}` criterion (19.99 USD in minor units), which
the deployed Lock Server accepts unchanged and the fiat-verifier gateway
settles through Stripe test mode. `GUARDED_PATH` picks the guarded upload path
(default `content/premium.txt`). After `proof`, `checkout <bundleId>` fetches
the hosted Stripe Checkout URL from the gateway (`FIAT_URL` env, default the
deployed staging gateway); `status` can be pointed at the gateway with
`PAYKIT_URL=https://fiat-verifier-production.up.railway.app` — BTC bundles are
answered by verbatim proxy to paykit-server, fiat bundles from gateway state.

## Staging-homeserver identities

The full guarded-content purchase requires identities on a homeserver that
supports `/priv/` writes (the production pubky.app homeserver rejects them;
the official staging homeserver accepts them). With a signup token:

```
node driver.mjs gen ids/creator.secret
CREATOR_SECRET_FILE=ids/creator.secret node driver.mjs signup CREATOR <token>
```

`CREATOR_SECRET_FILE` / `READER_SECRET_FILE` (base64url 32-byte secrets from
`gen`) take precedence over the legacy recovery-file identities for every
subcommand.

Note: canonical creator identifiers in Paykit/Locks request bodies are
`pubky`-prefixed app keys; bare z32 is rejected as non-canonical
(`invalid_request`).

## reader-mainnet: receiving the private Payment Request

The upstream `paykit-reader-demo` (the Bitkit protocol role that receives the
private Payment Request carrying the invoice address) is hardcoded to the
local Pubky testnet, so it cannot talk to the deployed mainnet-network rails.
`reader-mainnet/` builds the binary from the same pinned revisions as the
deployed Paykit Server with one fail-closed patch: setting
`PAYKIT_READER_PUBKY_TESTNET_HOST=mainnet` selects the Pubky SDK's default
mainnet client (the identical construction paykit-server uses for
`[paykit] network = "mainnet"`).

```
docker build -t paykit-reader-mainnet:f38c7915 reader-mainnet/

# prepare (publishes the receiver marker with a real Noise key)
printf '{"version":1,"operation":"prepare","reader_secret":"%s"}' "$(cat ids/reader.secret)" | \
docker run --rm -i -v "$PWD/reader-state:/reader-state" \
  -e PAYKIT_READER_STATE_PATH=/reader-state/state.bin \
  -e PAYKIT_READER_PUBKY_TESTNET_HOST=mainnet \
  -e PAYKIT_READER_RECEIVER_PATH=bitkit/server \
  -e PAYKIT_READER_SERVER_PATH=bitkit/server \
  -e PAYKIT_READER_SERVER_PUBKY=<creator-z32> \
  paykit-reader-mainnet:f38c7915

# receive (after the proof bundle triggers the invoice; same env, operation=receive)
```

Use a fresh reader per purchase run: an invoice is bound to its reader, and a
reused reader surfaces older (already paid) Payment Requests.

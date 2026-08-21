# pubky-payment-rails

Railway deployment of the Pubky marketplace staging payment rails: Lock Server
(pubky/locks) + Paykit Server (pubky/paykit-server) + Bitcoin Core regtest +
Fulcrum, running real payment mechanics with valueless regtest coins.

This is the hosted version of the locally verified `payments-env` composed
Docker environment. Every component is pinned to the exact upstream revision /
image digest that passed the full end-to-end payment verification there.

**REGTEST ONLY.** Nothing in this repo may ever be configured for Bitcoin
mainnet. The Pubky side, by contrast, deliberately runs against the real
(mainnet) Pubky DHT/relays - see "Identity network" below.

## Identity network: official staging Pubky network, not a private testnet

The local payments-env pinned its own `pubky-testnet`. This deployment does
not. Both servers are configured with `network = "mainnet"`, which makes the
pinned Pubky SDK (pkarr 6.0.1) resolve identities through its default relays
`https://pkarr.pubky.app` and `https://pkarr.pubky.org` - the same relays the
official staging Pubky network (homeserver
`ufibwbmed6jeq9k4p583go95wofakh9fwpp4k734trq79pd9u1uy` /
`https://homeserver.staging.pubky.app`) publishes through. Users of the
staging pubky-app can therefore act as marketplace sellers (creators) and
buyers (readers) directly against these rails; no separate identity network
exists in this deployment.

## Pinned revisions

| Component | Source | Revision |
| --- | --- | --- |
| Lock Server | `pubky/locks` | `ba49a777a94db318ec6ebd427315080a5b904645` |
| Paykit Server | `pubky/paykit-server` | `f38c7915e6b9b104e040773e78438f8aa984c46c` |
| paykit-rs (build dep) | `pubky/paykit-rs` | `52a852995bfc457b78d32f5a45f6741766a89bba` |
| locks-core (build dep) | `pubky/locks` | `df5ea1b6d8dcdec3a9b5a915c3f57bca69d75c8a` |
| bitcoind | `bitcoin/bitcoin:29.1` | `sha256:de62c536feb629bed65395f63afd02e3a7a777a3ec82fbed773d50336a739319` |
| Fulcrum | `cculianu/fulcrum:v2.0.0` | `sha256:cb1c006d0cff104696f4791d0f1516699b2c163120165461385e4de206271943` |

The Rust Dockerfiles clone the upstream repos at build time and fail closed if
the checkout does not match the pin. The Paykit build additionally runs the
upstream `prepare-local-docker-sources.sh`, which aborts if the supplied trees
drift from the dependency pins committed in paykit-server's manifests.

## Topology (Railway project `pubky-marketplace-staging`)

```text
pubky-app (Vercel)  ──HTTPS──►  locks-server  ──private──►  paykit-server
marketplace-service ──private─►  (public domain)             (public domain: /setup only surface used)
                                     │                            │
                                     ▼ signed HTTP                ▼ electrum
                              paykit-server ◄──trusted key   fulcrum ──► bitcoind ◄── miner
                                     │                        (public TCP proxy        (private, RPC)
                              locks-postgres                   for Bitkit)
                              paykit-postgres
```

| Railway service | Built from | Listens | Exposure |
| --- | --- | --- | --- |
| `locks-server` | `locks-server/Dockerfile` | `[::]:3000` | public HTTPS domain + private |
| `paykit-server` | `paykit-server/Dockerfile` | `[::]:3001` | public HTTPS domain (setup UI) + private |
| `bitcoind` | `bitcoind/Dockerfile` | `[::]:18443` RPC | private only |
| `fulcrum` | `fulcrum/Dockerfile` | `[::]:50001` TCP | private + public TCP proxy (Bitkit) |
| `miner` | `miner/Dockerfile` | - | none (RPC client loop) |
| `locks-postgres` | Railway managed Postgres | 5432 | private only |
| `paykit-postgres` | Railway managed Postgres | 5432 | private only |

Inter-service links use Railway private networking
(`<service>.railway.internal`, IPv6), which is why every listener binds the
IPv6 wildcard.

## Service environment variables

### bitcoind
- `BITCOIND_RPC_USER`, `BITCOIND_RPC_PASS` - regtest RPC credentials (random,
  never leave the project).
- Volume mounted at `/data`.

### miner
- `BITCOIND_RPC_HOST` = `bitcoind.railway.internal`
- `BITCOIND_RPC_USER`, `BITCOIND_RPC_PASS`
- `MINE_INTERVAL_SECONDS` (default 45) - one block per interval; bootstraps
  the chain to 101 blocks on first run so coinbase coins mature.

### fulcrum
- `BITCOIND_RPC_HOST`, `BITCOIND_RPC_USER`, `BITCOIND_RPC_PASS`
- `FULCRUM_TCP_BIND` (default `:::50001`, i.e. IPv6 wildcard dual-stack)
- Volume mounted at `/data`.

### locks-server
- `LOCKS_KEYPAIR_SEED` - `keypair-seed:<base64url-no-pad-32B>` signing seed.
  Generated once at deploy time; it IS the Lock Server identity.
- `LOCKS_PUBLIC_KEY` - `pubky<z-base32>` public key derived from the seed.
- `LOCKS_PUBLIC_DOMAIN` - the Railway public domain (no scheme); advertised in
  the server's PKARR record (ICANN HTTPS record, port 443).
- `PUBKY_LOCK_DATABASE_URL` - references `locks-postgres`.
- `PUBKY_LOCK_CREATOR_AUTH_ENCRYPTION_KEY` - base64url-no-pad 32B key
  encrypting creator authority at rest.
- `LOCKS_ALLOWED_RETURN_ORIGINS` - comma-separated origins allowed to receive
  `/connect` callback codes (the Vercel app origin).
- `LOCKS_PAYKIT_SERVER_URL` (default `http://paykit-server.railway.internal:3001`)
- `LOCKS_PAYKIT_MIN_CONFIRMATIONS` (default 1)
- `LOCKS_PKDNS_PUBLIC_IP` - advisory A-record IP for the PKARR packet; HTTP
  clients use the ICANN domain record.

### paykit-server
- `PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY` - must equal `LOCKS_PUBLIC_KEY`.
  Immutable deployment metadata: if the Lock Server identity is ever rotated,
  wipe/replace `paykit-postgres` in the same operation.
- `PAYKIT_DATABASE_URL` - references `paykit-postgres`.
- `PAYKIT_MASTER_KEY` - base64url-no-pad 32B master key.
- `PAYKIT_SETUP_ALLOWED_ORIGINS` - comma-separated origins for the hosted
  `/setup` page (the Vercel app origin).
- `PAYKIT_ELECTRUM_ENDPOINT` (default `tcp://fulcrum.railway.internal:50001`)

## Secrets handling

No secret is committed to this repo. All secrets are Railway service
variables, generated fresh at deploy time (`openssl rand`), distinct from
every local payments-env dev value. The Lock Server seed and the derived
public key live only in Railway variables (plus the operator's offline
records). The marketplace-service consumes `LOCKS_SERVER_URL`,
`LOCKS_BUNDLE_ENCRYPTION_KEY`, `LOCKS_LOOKUP_HMAC_KEY` (fresh 32-byte hex
keys, all-or-nothing fail-closed enablement).

## Consumers

- **marketplace-service** (same Railway project): `LOCKS_SERVER_URL` points at
  the Lock Server over private networking.
- **pubky-app on Vercel**: `PUBKY_RUNTIME_LOCKS_URL` = Lock Server public
  HTTPS URL; `PUBKY_RUNTIME_PAYKIT_SETUP_URL` = Paykit public HTTPS URL +
  `/setup`.
- **Bitkit (regtest dev build)**: Electrum endpoint = the Fulcrum public TCP
  proxy `host:port` recorded in the deployment notes.

## Deploy / redeploy

Each service deploys from its subdirectory with the Railway CLI (project
`pubky-marketplace-staging`, environment `production`):

```bash
railway up --service locks-server --path-as-root locks-server --detach
railway up --service paykit-server --path-as-root paykit-server --detach
railway up --service bitcoind --path-as-root bitcoind --detach
railway up --service fulcrum --path-as-root fulcrum --detach
railway up --service miner --path-as-root miner --detach
```

Rebuilding is deterministic: sources are cloned at the pinned revisions during
the image build. To bump a pin, change the `ARG` default in the service's
Dockerfile and redeploy that service.

State-reset rules (mirror the payments-env volume-coherence note):
- Wiping `paykit-postgres` alone is safe (loses invoices/creators; creators
  re-run setup).
- Rotating the Lock Server seed requires wiping BOTH `locks-postgres` state
  derived from the old identity AND `paykit-postgres`, and updating
  `PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY` - otherwise Paykit rejects every signed
  call from the new identity.
- Wiping the `bitcoind` volume resets the chain; Fulcrum's `/data` volume must
  be wiped with it, and any creator watch-only balances vanish (regtest coins
  are valueless by design).

# infra/ - mainnet stack IaC and cutover runbook (W1.6)

Deployment-side tooling for the watch-only Bitcoin payment rail, implementing
the frozen design (mp-btc-design `docs/ecommerce/btc-mainnet.md` r13,
§B.1 "Three stacks, no shared database", §B.2, §C rows 6/8/12/13). All scripts
are POSIX sh; prerequisites are the Railway CLI (authenticated), `openssl`,
and nothing else.

| File | Purpose |
| --- | --- |
| `create-stack.sh` | Idempotent IaC for the `proof` or `production` stack: service + Postgres in the right project, §C.12 variables, per-stack trust keys generated only if absent, image digest mandatory. |
| `miswiring-gate.sh` | The §B.1 negative gate: a mainnet config pointed at a wrongly-initialised database must refuse to boot with `StartupError::Deployment`. |
| `drop-proof-database.sh` | DESTRUCTIVE. Drops `paykit-proof-postgres` after the proofs, behind layered guards. |
| `tests/` | Shim (`fake-railway.sh`, `fake-paykit-server.sh`) and test suites. The scripts are exercised ONLY against the shim here; a human operator runs them against real Railway. |

## The three stacks (§B.1)

| Stack | Project | Service | Database |
| --- | --- | --- | --- |
| regtest | `pubky-marketplace-staging` (`c991d768`) | `paykit-server` (existing, **untouched by these scripts**) | `paykit-postgres` |
| proof | `pubky-marketplace-staging` (`c991d768`) | `paykit-server-proof` | `paykit-proof-postgres` |
| production | `pubky-marketplace-production` (`75faa4fe`) | `paykit-server-mainnet` | `paykit-mainnet-postgres` |

The proof database is **dropped, never cleaned, never promoted**. Production
is created **empty**, after the fork changes land. Trust keys
(`PAYKIT_MASTER_KEY`, `PAYKIT_REQUEST_SIGNING_KEY`) are per-stack, generated
by `create-stack.sh` at the moment that stack is built — production keys do
not exist while the proof stack is being built.

## Cutover order of operations

1. **Build once.** From the commit containing §C steps 1-6, build the image a
   single time and record its immutable digest **`D`** (`sha256:...`).
   This is the only build; every stack runs exactly `D` (§C.8, NEW-4).
2. **Create the proof stack:**
   ```sh
   infra/create-stack.sh proof \
     --image-digest sha256:<D> \
     --locks-public-key pubky<the Lock Server public key> \
     --allowed-origins "https://<staging shop origin>" \
     --marketplace-trusted-keys "pubky<staging marketplace signing key>"
   ```
   Then perform the printed OPERATOR ACTION: pin the
   `paykit-server-proof` deployment source to digest `D` in the Railway
   dashboard and redeploy.
3. **Verify the boot line** on `paykit-server-proof`: it must print
   `image sha256:<D>`, `network mainnet`, `stack_role proof`,
   `electrum bitkit.to:9999`. Every later proof asserts the digest it
   observed equals `D` before running.
4. **Run the miswiring gate (proof).** Point the proof config at the existing
   **regtest** database and assert refusal:
   ```sh
   # export the proof stack's real variables from Railway (never on a command line)
   GATE_DATABASE_URL=<DATABASE_URL of the regtest paykit-postgres> \
     infra/miswiring-gate.sh --role proof
   ```
   Expected: `PASS - ... refused to boot ... StartupError::Deployment`.
   See the script header for exactly what is asserted and why.
5. **Run the §D proofs** (MAINNET-NEG, MAINNET-DERIVE, staging Shop) on the
   proof stack.
6. **Create the production stack** — only now, with the fork changes landed,
   so the database is born empty of pre-floor invoices:
   ```sh
   infra/create-stack.sh production \
     --image-digest sha256:<SAME D> \
     --locks-public-key pubky<...> \
     --allowed-origins "https://<production shop origin>" \
     --marketplace-trusted-keys "pubky<production marketplace signing key>"
   ```
   Pin digest `D` on `paykit-server-mainnet` as printed, redeploy, and check
   the boot line shows `stack_role production` and digest `== D`.
7. **Run the miswiring gate (production):** production config against the
   **proof** database (`GATE_DATABASE_URL` of `paykit-proof-postgres`,
   `--role production`) — must refuse with `StartupError::Deployment`.
8. **Cut over** per §C.18 (owner sign-off gate): production Shop origin into
   `PAYKIT_SETUP_ALLOWED_ORIGINS`, `PAYKIT_SERVER_URL` on production
   `marketplace-service`, `PUBKY_RUNTIME_PAYKIT_SETUP_URL` on Vercel,
   redeploy both.
9. **After the wave report is archived**, drop the proof database:
   ```sh
   PAYKIT_PROOF_DROP_CONFIRM=c991d768 \
     infra/drop-proof-database.sh --i-understand-this-drops-the-proof-database
     # read the plan; then re-run with --execute appended to act
   ```

## Electrum endpoints (§B.2)

- **Wired by the scripts:** `ssl://bitkit.to:9999` — Synonym's mainnet
  electrs, the same server Bitkit mainnet builds use.
- **Documented failover only:** `ssl://electrum.blockstream.info:50002` —
  an unrelated operator with no SLA and aggressive limits. Use it only while
  `bitkit.to` is impaired: set `PAYKIT_ELECTRUM_ENDPOINT` on the affected
  service and redeploy (a variable change does not rebuild the image, so the
  digest stays `D`). Note the §B.7.1 auto-hide behaviour: three failed probes
  hide Bitcoin at checkout by design; that is the rail protecting sellers,
  not the incident itself. Fail over back as soon as `bitkit.to` recovers.

## Rollback / kill switch (§C.16, summary)

`PAYKIT_BITCOIN_CREATION_ENABLED=false` on the mainnet service + redeploy
refuses new payment requests while `activate`/`void`/`resolve` and existing
invoice observation keep working. The full drain-safe rollback order is §C.16
verbatim in the design; do not improvise it.

## Railway CLI invocations the operator MUST verify before first real use

These spellings are what the scripts issue. They were written against the
documented CLI surface but must be confirmed against the installed CLI
(`railway --version`) before the first real run, and the shim
(`tests/fake-railway.sh`) implements exactly this subset:

- `railway link --project <id>`
- `railway status --json` (the scripts parse `"project":{"id":"..."}`)
- `railway service <name>` (select/verify a service; non-zero exit if absent)
- `railway add --service <name>` (create an empty service)
- `railway add --database postgres --name <name>` (create Postgres)
- `railway variables --kv` (read `KEY=VALUE` lines for the selected service)
- `railway variables set KEY=VALUE` (non-secret values)
- **`railway variables set KEY` with the value piped on stdin** — used for
  generated trust keys so the value never touches a command line, log, or
  file. If the installed CLI has no stdin form, the documented fallback is an
  operator shell with history disabled:
  `railway variables set KEY="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"`.
- `railway down --service <name>` (the one destructive call in
  `drop-proof-database.sh`; confirm it removes the database service and its
  volume on the installed CLI version)
- **Image-digest pinning has no confident CLI spelling** — pin the deployment
  source to digest `D` in the Railway dashboard (service Settings → Source),
  as `create-stack.sh` prints at the end of every run.

## Tests

Run from the repo root (all use `RAILWAY_BIN=./infra/tests/fake-railway.sh`;
nothing touches real Railway):

```sh
sh infra/tests/create-stack_test.sh
sh infra/tests/miswiring-gate_test.sh
sh infra/tests/drop-proof-database_test.sh
```

The shim records every call as `READ` / `LOCAL` / `MUTATE` with **all
variable values redacted**, so the tests can assert idempotency (second run =
zero `MUTATE` lines) and that no secret ever reaches a log.

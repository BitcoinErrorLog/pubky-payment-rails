# infra/ - mainnet stack IaC and cutover runbook (W1.6)

Deployment-side tooling for the watch-only Bitcoin payment rail, implementing
the frozen design (mp-btc-design `docs/ecommerce/btc-mainnet.md` r13,
§B.1 "Three stacks, no shared database", §B.2, §C rows 6/8/12/13). All scripts
are POSIX sh; prerequisites are the Railway CLI (authenticated), `openssl`,
and nothing else.

## Deploy-target fork

The deploy target for `paykit-server/entrypoint.sh` and for the binaries the
stacks run is the fork's **marketplace mainnet-hardening line** — the line
checked out in the W1 hardening worktrees (`ps-w1-1` @ `8762fa2`,
`ps-observer-r6` @ `eed7d5b`; parse evidence:
`paykit-server/src/config.rs` reads `[deployment] stack_role` and
`bitcoin.creation_enabled` under `deny_unknown_fields` on that range). It is
**not** the stale `marketplace-rails` checkout at `92e3c84`, whose `RawConfig`
parses neither field and would refuse the rendered config.

The entrypoint contract test
(`paykit-server/tests/entrypoint_test.sh`, test 6) feeds the exact rendered
TOML to the real fork parser via `paykit-server --check-config <path>` and
requires `PAYKIT_FORK_DIR` to point at a checkout of this line. Run it
against a fork commit that has `--check-config` (the flag lands in a
parallel slice on the hardening line); against a checkout without the flag
the test **fails by design** — there is no fallback that passes without the
real parser.

| File | Purpose |
| --- | --- |
| `create-stack.sh` | Idempotent IaC for the `proof` or `production` stack: service + Postgres in the right project, §C.12 variables, per-stack trust keys generated only if absent, image digest mandatory. **Provisions only** — the deployment pin is a mandatory manual gate (below). |
| `miswiring-gate.sh` | The §B.1 negative gate: a mainnet config pointed at a wrongly-initialised database must refuse to boot with `StartupError::Deployment`. |
| `drop-proof-database.sh` | DESTRUCTIVE. Drops `paykit-proof-postgres` after the proofs, behind layered guards. **Never wired into CI or any unattended automation** — it is a manual, runbook-level tool only (see "Cutover order of operations", step 9). |
| `tests/` | Shims (`fake-railway.sh`, `fake-railway-no-stdin.sh`, `fake-paykit-server.sh`) and test suites. The scripts are exercised ONLY against the shims here; a human operator runs them against real Railway. |

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
   This **provisions** the stack (objects + variables); it deploys nothing.
   Then complete the printed **MANDATORY MANUAL GATE**: pin the
   `paykit-server-proof` deployment source to digest `D` in the Railway
   dashboard (service Settings → Source) and redeploy, then verify the boot
   line prints `image sha256:<D>`. The miswiring gate (step 4) is BLOCKED
   until both checklist boxes are ticked.
3. **Verify the boot line** on `paykit-server-proof`: it must print
   `image sha256:<D>`, `network mainnet`, `stack_role proof`,
   `electrum bitkit.to:9999`. Every later proof asserts the digest it
   observed equals `D` before running.
4. **Run the miswiring gate (proof).** Point the proof config at the existing
   **regtest** database and assert refusal:
   ```sh
   # select the regtest paykit-postgres service, then export its URL
   export GATE_DATABASE_URL="$(railway variables --kv | sed -n 's/^DATABASE_URL=//p')"
   infra/miswiring-gate.sh --role proof
   ```
   Never use the env-prefix inline form (`GATE_DATABASE_URL=... command`): an
   inline assignment is part of the typed line, so the URL — credentials and
   all — is recorded verbatim in your interactive shell history; `export` on
   its own line (or `read -r` from a prompt) keeps it out.
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
   Pin digest `D` on `paykit-server-mainnet` as printed (the same mandatory
   manual gate), redeploy, and check the boot line shows
   `stack_role production` and digest `== D`.
7. **Run the miswiring gate (production):** production config against the
   **proof** database — select the `paykit-proof-postgres` service, then:
   ```sh
   export GATE_DATABASE_URL="$(railway variables --kv | sed -n 's/^DATABASE_URL=//p')"
   infra/miswiring-gate.sh --role production
   ```
   (Same shell-history rule as step 4: export, never the inline env-prefix
   form.) Must refuse with `StartupError::Deployment`.
8. **Cut over** per §C.18 (owner sign-off gate): production Shop origin into
   `PAYKIT_SETUP_ALLOWED_ORIGINS`, `PAYKIT_SERVER_URL` on production
   `marketplace-service`, `PUBKY_RUNTIME_PAYKIT_SETUP_URL` on Vercel,
   redeploy both.
9. **After the wave report is archived**, drop the proof database. **First
   edit `PROOF_PROJECT_ID` in `infra/drop-proof-database.sh` to the FULL
   proof project id** — the shipped value is the documented 8-char prefix
   and the exact-equality guard refuses anything but the full id, so as
   shipped the script cannot execute against real Railway (fail-closed, by
   design); `PAYKIT_PROOF_DROP_CONFIRM` must then equal that same full id:
   ```sh
   PAYKIT_PROOF_DROP_CONFIRM=<full proof project id> \
     infra/drop-proof-database.sh --i-understand-this-drops-the-proof-database
     # read the plan; then re-run with --execute appended to act
   ```
   **`drop-proof-database.sh` is never wired into CI or any unattended
   automation — not as a pipeline step, not as a scheduled job, not behind a
   webhook.** It is a manual, runbook-level tool: destruction requires three
   independent operator artifacts present at once (the long acknowledgement
   flag, the `PAYKIT_PROOF_DROP_CONFIRM` env equal to the immutable proof
   project id literal in the script, and `--execute`), and none of them may
   ever be stored where automation could replay them. The proof project id
   is an immutable literal in the script; no environment variable (including
   `PAYKIT_PROOF_PROJECT_ID`, which the script does not read) can retarget
   it.

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
  file. `create-stack.sh` verifies each write by readback. **If the
  installed CLI has no stdin form: STOP.** Do not put the generated key on a
  command line (it would leak into shell history, process tables, and logs)
  — set `PAYKIT_MASTER_KEY` / `PAYKIT_REQUEST_SIGNING_KEY` through Railway's
  dashboard variable editor (or another verified non-argv channel), then
  re-run `create-stack.sh`; existing keys are never regenerated.
- `railway down --service <name>` (the one destructive call in
  `drop-proof-database.sh`; confirm it removes the database service and its
  volume on the installed CLI version)
- **Image-digest pinning has no verified CLI operation** — it is a
  mandatory manual gate: pin the deployment source to digest `D` in the
  Railway dashboard (service Settings → Source) and redeploy, as
  `create-stack.sh` prints as a checklist at the end of every run. The
  miswiring gate is BLOCKED until the operator has ticked the pin and the
  boot-line verification.

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
`fake-railway-no-stdin.sh` emulates a CLI without the stdin form of
`variables set KEY`; the create-stack suite proves the script refuses it
rather than falling back to argv.

The entrypoint suite additionally feeds the rendered config to the REAL fork
parser (see "Deploy-target fork"):

```sh
PAYKIT_FORK_DIR=<deploy-target fork checkout> sh paykit-server/tests/entrypoint_test.sh
```

`PAYKIT_FORK_DIR` must name a fork checkout on the marketplace
mainnet-hardening line **that has `--check-config`**; unset, a checkout
without `stack_role` in `paykit-server/src/config.rs`, or a checkout without
the flag all FAIL the contract test loudly — never skip.

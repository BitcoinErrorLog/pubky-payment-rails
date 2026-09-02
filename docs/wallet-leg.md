# Wallet Leg: Real Bitkit iOS Against the Deployed Regtest Rails

Date: 2026-08-21. This documents the one previously unproven leg of the
marketplace payment story: a real Bitkit wallet (not the demo reader binary)
performing its role against the deployed Railway rails
(`pubky-marketplace-staging`): approving the `watch-only-account-v1`
companion claim (leg A, seller side) and receiving + paying a private Paykit
Payment Request in-app (leg B, buyer side).

Evidence (screenshots, logs) lives in `$WALLET_LEG_EVIDENCE_DIR` on the
machine that ran this. Every claim below is backed by a file there or by a
log excerpt reproduced inline.

## Platform choice: Bitkit iOS

- `bitkit-ios` (native Swift) has the full Paykit integration: pubkyauth
  companion-claim parsing (`PubkyAuthRequest.swift` handles
  `x-bitkit-claim=watch-only-account-v1`), `WatchOnlyAccountService` (xpub
  export + claim payload), a Paykit UI behind the `paykitUiEnabled`
  UserDefaults flag, private-contact payments, and incoming Payment Request
  presentation (`AppScene.presentNextIncomingPaykitPaymentRequest`).
- `bitkit-android`'s checkout had no equivalent claim-approval surface, and
  the Android SDK tooling was not on PATH on this machine.
- Debug builds of bitkit-ios default to regtest and allow the Electrum server
  to be overridden (`electrumServer` UserDefaults key, JSON-encoded
  `ElectrumServer`).

## Environment

- Two iPhone 16 Pro simulators (iOS 18.3.1): seller `$SELLER_UDID`, buyer
  `$BUYER_UDID`.
- Build: `xcodebuild -project Bitkit.xcodeproj -scheme Bitkit -configuration
  Debug -derivedDataPath "$WALLET_LEG_EVIDENCE_DIR/derived"` — derived data
  must live on APFS (the ExFAT external volume breaks binary-xcframework
  extraction), and code signing must stay enabled (ad-hoc) or the app-group
  entitlement is stripped and the app crashes at launch.
- Config seeded via `simctl spawn "$SELLER_UDID"` / `"$BUYER_UDID"`
  `defaults write to.bitkit ...`: `paykitUiEnabled = true`, `electrumServer`
  pointed at the deployed Fulcrum public TCP endpoint
  `$FULCRUM_PUBLIC_HOST:$FULCRUM_PUBLIC_PORT`.
- UI automation: `idb` (Facebook) inside a Python 3.9 venv (fb-idb is broken
  on Python 3.14); helper script `$WALLET_LEG_EVIDENCE_DIR/ui.sh`.
  `pubkyauth://` URLs cannot be deep-linked (`pubkyauth` is only in
  `LSApplicationQueriesSchemes`, not `CFBundleURLTypes`); paste them into the
  in-app scanner via `simctl pbcopy` instead.
- Funding: `railway ssh --service bitcoind -- bitcoin-cli -regtest
  -rpcuser=... -rpcpassword=... sendtoaddress <addr> ...` plus the deployed
  auto-miner (45 s blocks). RPC credentials come from the bitcoind service
  environment (`BITCOIND_RPC_USER` / `BITCOIND_RPC_PASS`), never from this
  repo.
- Identities: Bitkit provisions its pubky through Homegate automatically
  during profile creation; both wallets got real identities on the staging
  homeserver (seller `$SELLER_PUBKY`, buyer `$BUYER_PUBKY`).

## Leg A (seller approves the watch-only companion claim): PASS

Driver side (`verify/driver.mjs`, new subcommands added for wallet legs):

1. `connect-start` prints the locks pubkyauth URL; Bitkit scans it (pasted
   from clipboard), shows the permission sheet, and the user approves —
   `seller-17-scanner.png` … `seller-22-claim-success.png`.
2. `setup-start` fetches the Paykit `/setup` flow; its `authUrl` carries
   `x-bitkit-claim=watch-only-account-v1`. Bitkit's approval sheet shows the
   dedicated watch-only consent step; approving exports the account xpub and
   activates tracking — `seller-23-before-scan.png` …
   `seller-27-authorized.png`.
3. `setup-poll` completed with HTTP 200: the deployed paykit-server accepted
   the claim, derived the watch-only account, and persisted it.

So a real wallet can onboard as a marketplace seller: the deployed server
watches a Bitkit-held account via the claim, with no spending authority.

### Caveat discovered: Homegate-provisioned identities have a restricted write allowlist

The staging homeserver allows Bitkit/Homegate-provisioned users to write
`/pub/paykit/**` but returns `403 Write to this path is not allowed` for
`/pub/locks.app/**` and `/pub/pubky.app/**` (isolated with a direct
delegated-session probe; the locks server surfaces this as a 500 on
`publish`). Publishing marketplace content as the Bitkit seller identity is
therefore blocked server-side. For leg B the content creator is a
driver-held identity (admin-token signup, full allowlist):
`$CREATOR_PUBKY`; the wallet under test is the buyer, which is the leg
that needed proving.

## Leg B (buyer receives + pays the private Payment Request)

### Deployed-server defects found and fixed (each masked by the demo reader)

The deployed paykit-server (pinned upstream rev `f38c7915`) produced payment
material a real wallet rejects. Three distinct defects, found one at a time
because each is silently filtered at a different layer of Bitkit/paykit-rs:

1. **Mainnet endpoint identifier on regtest.** Invoice intents hardcoded
   `btc-bitcoin-p2wpkh`; Bitkit filters endpoints whose network segment
   doesn't match its chain. Fixed by making `PaykitIntentBuilder`
   network-aware (`btc-regtest-p2wpkh` on regtest).
2. **Uppercase amount asset.** Terms used `"BTC"`; the Payment Requests spec
   makes `amount.asset` case-sensitive lowercase and Bitkit's
   `PaykitPaymentRequestService` filters on `asset == "btc"`. Fixed to
   `"btc"`.
3. **Bare-string endpoint payload.** `receiving_details` published the raw
   address as the endpoint payload. The payment-endpoint-identifier spec
   (§7) recommends a JSON object `{"value": "<address>"}` and Bitkit's
   `parsePayload` requires it; bare strings are dropped, so the SDK resolved
   the private payment list with candidates present but zero supported
   endpoints (`status=unsupportedEndpoint`). Fixed to publish
   `{"value": address}`.

All three fixes live in
`paykit-server/regtest-endpoint-identifier.patch`, applied fail-closed in
`paykit-server/Dockerfile` (`git apply` + `grep` guards abort the build on
drift). The demo reader asserted the server's own output rather than the
spec (hard-required uppercase `"BTC"`, `btc-bitcoin-p2wpkh`, and a raw
address payload), so server and reader could drift from the spec together
and stay green (mirror-coupling / shared fixtures).

### Deployment detail: Railway's builder was bypassed

Railway's Metal builder failed repeatedly with no logs ("scheduling build on
Metal builder"), and the legacy build environment could not be forced. The
image is built locally for `linux/amd64` (`docker buildx`), pushed to the
anonymous `ttl.sh` registry, and the Railway service source is pointed at
that prebuilt image via the GraphQL API.

### Wallet-side findings (bitkit-ios / paykit-rs / pubky-noise)

- **Payment requests only flow from linked peers.** Bitkit polls
  `receivePrivateMessagesFromLinkedPeers`; the counterparty must be added as
  a contact first (`buyer-addcontact-*.png`). Until then nothing is polled.
- **A missing message slot silently stalls the channel.** The deployed
  server's noise channels consistently show a gap at slot index 1 (observed
  on two independent channels). pubky-noise's `receive_messages` treats a
  404 at the read counter as "no more messages", so slots ≥ 2 are never
  read. Workaround used here: write an undecryptable blob into the missing
  slot with the creator's key; the SDK then skips past it. The slot-1 gap
  looks like a paykit-server bug worth upstream attention.
- **A wallet that ever synced a different regtest chain poisons its locktime.**
  The buyer wallet briefly synced Bitkit's default staging regtest Electrum
  (chain height ~160623) before the Fulcrum override was applied. ldk-node
  keeps that height as its best tip (the deployed chain, height ~1114, looks
  shorter, and wallet state lives in the remote VSS store, so reinstalling the
  app does not clear it). Anti-fee-sniping then stamps every send with
  `nLockTime=160623`, which the deployed bitcoind rejects as non-final — the
  wallet shows "Bitcoin Sent" but the transaction never enters the mempool
  (LDK logs a successful Electrum broadcast; the daemon quietly drops it).
  Remediation used here: mine the deployed regtest chain past the stale tip
  so the locktime becomes valid. For future wallet-leg runs: seed the
  Electrum override BEFORE the wallet's first launch.
- **Presentation failures are silent by design.** If a pending request can't
  be opened (e.g. `noEndpoint` from the unsupported-payload defect), Bitkit
  defers it and gives up after 5 attempts with a single log line
  (`Stopped retrying incoming Paykit payment request after 5 presentation
  attempts`). Temporary diagnostic logging added to a local build
  (`WALLETLEG` lines in `PrivatePaykitService+Payments.swift` /
  `AppScene.swift`) was required to see the resolution outcome
  (`state=available status=unsupportedEndpoint ... payableCount=0`).

### Outcome

**Proven with saved evidence** (screens `legb9-buyer-sheet.png`,
`legb9-buyer-afterswipe2.png`, log `logs/legb-walletleg-trace.log`):
after the payload-fixed server was deployed and proof bundle
`01M0JZKMC4Q2DWAVG45D3RZX7W` submitted, the buyer's Bitkit resolved the
request as payable (`status=payable`, endpoint `btc-regtest-p2wpkh`,
payload `{"value":"bcrt1qy20..."}`), presented the in-app Payment Request
sheet (₿15,000 / $9.99), and on swipe signed and broadcast tx
`66263f18c20d6e04a2b782c7be4c91dc18ddb8d0fde32200081a0fc0a586a6c8`
("Bitcoin Sent" confirmation shown).

**Not proven — on-chain confirmation / order completion.** The broadcast
transaction carries `nLockTime=160623` (see the poisoned-tip finding above)
and is non-final on the deployed chain, so it never entered the mempool and
the bundle stayed `pending`. Remediation (mining the chain past 160623 with
`setmocktime`) was underway — chain taken from ~1,114 to ~71,563 of the
required ~160,624 blocks — when the run was stopped. Once the chain passes
that height the wallet's transaction becomes final and can be
confirmed/rebroadcast (e.g. via Bitkit's Boost) to complete the bundle.

## Completion: fresh buyer wallet, on-chain finality (2026-08-22)

The unresolved item above — on-chain confirmation / order completion — is now
proven, using a completely fresh buyer wallet with the Electrum override
seeded BEFORE first launch (evidence: `finality-*` files in
`$WALLET_LEG_EVIDENCE_DIR`, details in `finality-verification.txt`).

- Fresh simulator (erased), app installed, `electrumServer` +
  `paykitUiEnabled` defaults written before the first launch. The wallet's
  first sync went from genesis straight to the deployed chain
  (`height 0 -> 77304`, `finality-buyer-wallet.log`) — no staging contact,
  so no poisoned locktime.
- New buyer identity `$BUYER_PUBKY` (Homegate signup during profile
  creation), funded 100,000 sats, creator `$CREATOR_PUBKY` added as
  contact.
- Proof bundle `DHWGS5V5A3RCQ7YGQAHWVVVNX0` against the existing lock
  `.../ZP01RWZK...JDT50.json`; the Payment Request (₿15,000 / $9.99,
  `btc-regtest-p2wpkh`) arrived and was presented in-app with **no noise
  slot-gap stall this run** — no fillslot workaround needed
  (`finality-21-request-sheet.png`).
- Swipe-to-pay broadcast tx
  `cc85df0e24b54be353a57700429d144b35264c1af97f3de41c503dc52f1e4792` with a
  sane `nLockTime=77317`; the auto-miner confirmed it in block
  `50be290f...ed89e` at **height 77318**. Bitkit's activity detail shows
  Confirmed (`finality-25-activity-detail.png`).
- Seller side verified three ways: the watch-only `legb_creator` bitcoind
  wallet lists the 15,000-sat receive at height 77318; the deployed
  paykit-server completed the bundle (`status=completed`,
  `completed_at=2026-08-22T07:03:18Z`, ~12 s after broadcast); and an
  access credential was issued and the guarded content served
  (`read_status=200`).
- New operational finding: yesterday's guarded upload was gone (404 on
  read despite a valid credential). Re-uploading the original 45-byte body
  reproduced the lock's pinned hash exactly, after which the credentialed
  read returned the content. A later `/priv` durability probe (2026-08-28
  → 2026-08-29, ~25h, three files under `/priv/pubky.app/durability-probe/`,
  BLAKE3-verified green at T+1h and T+~25h) exonerated the staging
  homeserver's `/priv` storage engine for that window — but the window
  spanned no Lock Server redeploy, and the probe wrote to `/priv/pubky.app/`,
  not `/priv/locks.app/`. Remaining suspects are the Lock Server's
  imported-creator-session/serve layer and redeploy-triggered loss; the
  original 404's root cause is still not proven. Railway's last
  locks-server deploy before the 404 was 2026-08-21 14:03; the 404 was
  observed 2026-08-22; whether the vanished object was written before or
  after that deploy is unrecorded, so redeploy is an untested suspect, not
  a proven trigger. Re-publishing restores service; that is an operator
  note, not a cause.

## Fresh-run runbook (condensed)

1. Build bitkit-ios Debug for a simulator (APFS derived data, signing on).
2. Seed `paykitUiEnabled` + `electrumServer` defaults; onboard wallet;
   create profile (Homegate signup happens automatically); fund via railway
   bitcoind.
3. Seller: `driver.mjs connect-start` → paste URL into Bitkit scanner →
   approve; `connect-complete`; `setup-start` → paste authUrl → approve
   watch-only consent; `setup-poll` until 200.
4. Creator (driver-held): `gen`/`signup`, `connect`, `setup-start`/
   `setup-claim`/`setup-poll` with a fresh bitcoind-wallet tpub, `publish`
   (needs `LOCKS_PUBLIC_KEY`), `reader-marker` not needed for Bitkit buyers
   (the wallet publishes its own marker on contact add).
5. Buyer wallet: add the creator's pubky as a contact; keep the app
   foregrounded (poll backoff 30/60/120 s).
6. `driver.mjs proof <lockResource> <bundleId>` with `READER_PUBKY` set to
   the buyer's pubky; the send sheet appears in Bitkit; slide to pay.
7. Verify: `driver.mjs status <bundleId>` / `lifecycle` until the bundle
   completes after the auto-miner confirms.

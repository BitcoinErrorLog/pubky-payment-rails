#!/usr/bin/env node
// Verification driver for the DEPLOYED payment rails on Railway, adapted from
// payments-env/scripts/verify.sh. Runs against public HTTPS endpoints with
// throwaway identities that live on the real Pubky network (production
// pubky.app homeserver), resolved by the deployed servers through the same
// mainnet pkarr relays that staging app users publish to.
//
// Subcommands:
//   gen <file>                 - generate a throwaway keypair, save 32B secret (base64url)
//   signup <role> <token>      - sign the role's identity up on the staging homeserver
//   identities                 - print creator/reader pubkys
//   connect <state>            - full locks legacy-connect flow -> frontend session JSON
//   setup-start <state>        - fetch paykit /setup, print { flow, authUrl }
//   setup-claim <authUrl>      - print the companion claim JSON for paykit-companion-auth stdin
//   setup-poll <flow>          - poll POST /setup/<flow>/complete until 200
//   reader-marker              - publish the reader's paykit receiver marker
//   publish <sessionToken> <state> - lock-service-config + guarded upload + content lock
//   negative                   - unsigned/garbage-signed paykit business calls must 401
//   proof <lockResource> <bundleId> - submit proof bundle
//   status <bundleId>          - signed paykit /transactions/status (locks key)
//   lifecycle <bundleId>       - POST /verification-task-lookups
//   credential <bundleId>      - POST /access-credentials + guarded read
//   checkout <bundleId> [stripe|paypal] - fiat-verifier /checkout-sessions (hosted checkout URL)
//
// Fiat locks: ASSET=USD AMOUNT=<cents> selects the fiat criterion in `publish`;
// PAYKIT_URL can be pointed at the fiat-verifier gateway for `status`/`negative`.
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import crypto from 'node:crypto';
import { isAbsolute, resolve } from 'node:path';

function requireEnv(name) {
  const value = process.env[name];
  if (value === undefined || value === '') {
    throw new Error(`missing required environment variable: ${name}`);
  }
  return value;
}

const pubkySdkRequireSpec = requireEnv('PUBKY_SDK_REQUIRE');
const pubkySdkRequirePath = isAbsolute(pubkySdkRequireSpec)
  ? pubkySdkRequireSpec
  : resolve(process.cwd(), pubkySdkRequireSpec);
const require = createRequire(pubkySdkRequirePath);
const { Keypair, Pubky, PublicKey } = require('@synonymdev/pubky');

const LOCKS_URL = process.env.LOCKS_URL ?? 'https://locks-server-production.up.railway.app';
const PAYKIT_URL = process.env.PAYKIT_URL ?? 'https://paykit-server-production.up.railway.app';
// Must be one of the deployed servers' allowed origins (LOCKS_ALLOWED_RETURN_ORIGINS /
// PAYKIT_SETUP_ALLOWED_ORIGINS); localhost was removed at the fiat-rails cutover.
const RETURN_ORIGIN = process.env.RETURN_ORIGIN ?? 'https://shop.pubky.app';
const LOCKS_SEED_B64URL = process.env.LOCKS_SEED_B64URL; // seed only, no prefix
const GUARDED_BODY = process.env.GUARDED_BODY ?? 'deployed rails guarded bytes';
// Criterion terms. ASSET=USD (minor units in AMOUNT) authors a fiat lock that
// the fiat-verifier gateway settles through Stripe; BTC stays the default.
const ASSET = process.env.ASSET ?? 'BTC';
const AMOUNT = process.env.AMOUNT ?? process.env.AMOUNT_SATS ?? '15000';
const GUARDED_PATH = process.env.GUARDED_PATH ?? 'content/premium.txt';
// The fiat-verifier gateway's buyer-facing surface (checkout subcommand).
const FIAT_URL = process.env.FIAT_URL ?? 'https://fiat-verifier-production.up.railway.app';

function keypairFrom(file) {
  return Keypair.fromRecoveryFile(new Uint8Array(readFileSync(file)), requireEnv('RECOVERY_PASSWORD'));
}

// Wallet-leg runs use identities whose secrets live inside a real wallet
// (Bitkit); only the z32 public key is available to the driver.
function roleZ32(role) {
  const override = process.env[`${role}_PUBKY`];
  if (override) return override.replace(/^pubky/, '');
  return loadKeypair(role).publicKey.z32();
}

// CREATOR_SECRET_FILE / READER_SECRET_FILE (base64url 32B secrets from `gen`)
// take precedence over CREATOR_RECOVERY_FILE / READER_RECOVERY_FILE.
function loadKeypair(role) {
  const secretFile = process.env[`${role}_SECRET_FILE`];
  if (secretFile) {
    const secret = Buffer.from(readFileSync(secretFile, 'utf8').trim(), 'base64url');
    if (secret.length !== 32) throw new Error(`${role}_SECRET_FILE must decode to 32 bytes`);
    return Keypair.fromSecret(new Uint8Array(secret));
  }
  const recoveryFile = process.env[`${role}_RECOVERY_FILE`];
  if (!recoveryFile) {
    throw new Error(`missing required environment variable: ${role}_SECRET_FILE or ${role}_RECOVERY_FILE`);
  }
  return keypairFrom(recoveryFile);
}

async function signedInSigner(keypair) {
  const pubky = new Pubky();
  const signer = pubky.signer(keypair);
  let lastError;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      await signer.signinBlocking();
      return { pubky, signer };
    } catch (error) {
      lastError = error;
      // pkarr republish CAS conflicts are transient
      if (!String(error).includes('Compare and swap')) {
        try {
          const session = await signer.signin();
          return { pubky, signer, session };
        } catch (innerError) {
          lastError = innerError;
        }
      }
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
  throw lastError;
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);

  if (cmd === 'gen') {
    const file = args[0];
    if (!file) throw new Error('usage: gen <file>');
    const keypair = Keypair.random();
    writeFileSync(file, Buffer.from(keypair.secret()).toString('base64url') + '\n', { mode: 0o600 });
    console.log(JSON.stringify({ file, pubky: keypair.publicKey.z32() }));
    return;
  }

  if (cmd === 'signup') {
    const [role, token] = args;
    if (!['CREATOR', 'READER'].includes(role) || !token) throw new Error('usage: signup <CREATOR|READER> <token>');
    const keypair = loadKeypair(role);
    const homeserver = requireEnv('STAGING_HOMESERVER');
    const pubky = new Pubky();
    const session = await pubky.signer(keypair).signup(PublicKey.from(homeserver), token);
    console.log(JSON.stringify({
      role,
      pubky: keypair.publicKey.z32(),
      homeserver,
      session_pubky: session.info.publicKey.z32(),
    }));
    return;
  }

  if (cmd === 'identities') {
    const creator = loadKeypair('CREATOR');
    const reader = loadKeypair('READER');
    console.log(JSON.stringify({
      creator: creator.publicKey.z32(),
      reader: reader.publicKey.z32(),
    }));
    return;
  }

  if (cmd === 'connect') {
    const state = args[0];
    const res = await fetch(`${LOCKS_URL}/connect?return_to=${encodeURIComponent(`${RETURN_ORIGIN}/done`)}&state=${state}`);
    if (!res.ok) throw new Error(`GET /connect -> ${res.status}: ${await res.text()}`);
    const html = await res.text();
    const flowMatch = html.match(/action="\/connect\/([^"/]+)\/complete"/);
    const authMatch = html.match(/href="([^"]+)"/);
    if (!flowMatch || !authMatch) throw new Error('connect shell missing flow action or auth href');
    const flow = flowMatch[1];
    const authUrl = authMatch[1].replaceAll('&amp;', '&');
    console.error(`[connect] flow=${flow}`);

    const creator = loadKeypair('CREATOR');
    const { signer } = await signedInSigner(creator);
    await signer.approveAuthRequest(authUrl);
    console.error('[connect] auth approved by creator');

    const completion = await fetch(`${LOCKS_URL}/connect/${flow}/complete`, { method: 'POST', redirect: 'manual' });
    if (completion.status !== 303) throw new Error(`connect completion -> ${completion.status}: ${await completion.text()}`);
    const location = completion.headers.get('location');
    const code = new URL(location, RETURN_ORIGIN).searchParams.get('code');
    if (!code) throw new Error(`no code in completion redirect: ${location}`);

    const session = await fetch(`${LOCKS_URL}/frontend-sessions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code, state }),
    });
    const sessionJson = await session.json();
    if (!session.ok || !sessionJson.session_token) throw new Error(`frontend-sessions -> ${session.status}: ${JSON.stringify(sessionJson)}`);
    console.log(JSON.stringify(sessionJson));
    return;
  }

  // Split connect flow for wallet-leg runs: the pubkyauth approval happens in a
  // real wallet (Bitkit) instead of a driver-held keypair.
  if (cmd === 'connect-start') {
    const state = args[0];
    const res = await fetch(`${LOCKS_URL}/connect?return_to=${encodeURIComponent(`${RETURN_ORIGIN}/done`)}&state=${state}`);
    if (!res.ok) throw new Error(`GET /connect -> ${res.status}: ${await res.text()}`);
    const html = await res.text();
    const flowMatch = html.match(/action="\/connect\/([^"/]+)\/complete"/);
    const authMatch = html.match(/href="([^"]+)"/);
    if (!flowMatch || !authMatch) throw new Error('connect shell missing flow action or auth href');
    console.log(JSON.stringify({ flow: flowMatch[1], authUrl: authMatch[1].replaceAll('&amp;', '&') }));
    return;
  }

  if (cmd === 'connect-complete') {
    const [flow, state] = args;
    if (!flow || !state) throw new Error('usage: connect-complete <flow> <state>');
    const completion = await fetch(`${LOCKS_URL}/connect/${flow}/complete`, { method: 'POST', redirect: 'manual' });
    if (completion.status !== 303) throw new Error(`connect completion -> ${completion.status}: ${await completion.text()}`);
    const location = completion.headers.get('location');
    const code = new URL(location, RETURN_ORIGIN).searchParams.get('code');
    if (!code) throw new Error(`no code in completion redirect: ${location}`);

    const session = await fetch(`${LOCKS_URL}/frontend-sessions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code, state }),
    });
    const sessionJson = await session.json();
    if (!session.ok || !sessionJson.session_token) throw new Error(`frontend-sessions -> ${session.status}: ${JSON.stringify(sessionJson)}`);
    console.log(JSON.stringify(sessionJson));
    return;
  }

  if (cmd === 'setup-start') {
    const state = args[0];
    const res = await fetch(`${PAYKIT_URL}/setup?return_to=${encodeURIComponent(RETURN_ORIGIN)}&state=${state}`);
    if (!res.ok) throw new Error(`GET /setup -> ${res.status}: ${await res.text()}`);
    const html = await res.text();
    const flowMatch = html.match(/const flowId=("(?:[^"\\]|\\.)*");/);
    const authMatch = html.match(/<code>([^<]+)<\/code>/);
    if (!flowMatch || !authMatch) throw new Error('setup shell missing flowId or auth url');
    const flow = JSON.parse(flowMatch[1]);
    const authUrl = authMatch[1].replaceAll('&amp;', '&');
    console.log(JSON.stringify({ flow, authUrl }));
    return;
  }

  if (cmd === 'setup-claim') {
    const authUrl = args[0];
    const tpub = args[1];
    const creator = loadKeypair('CREATOR');
    const secret = Buffer.from(creator.secret()).toString('base64url');
    console.log(JSON.stringify({
      version: 1,
      auth_url: authUrl,
      creator_secret: secret,
      account_xpub: tpub,
      account_index: 0,
    }));
    return;
  }

  if (cmd === 'setup-poll') {
    const flow = args[0];
    const deadline = Date.now() + 120_000;
    for (;;) {
      const res = await fetch(`${PAYKIT_URL}/setup/${flow}/complete`, { method: 'POST' });
      const body = await res.text();
      if (res.status === 200) { console.log(body); return; }
      if (Date.now() > deadline) throw new Error(`setup never completed; last ${res.status}: ${body}`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }

  if (cmd === 'reader-marker') {
    const reader = loadKeypair('READER');
    const pubky = new Pubky();
    const session = await pubky.signer(reader).signinBlocking();
    // Receiver-scoped Noise key: fresh throwaway; we only need the marker to
    // exist so invoice creation can select it (we do not decrypt deliveries).
    const noise = Keypair.random();
    const marker = {
      version: 1,
      kind: 'paykit.receiver',
      receiver_path: 'bitkit/server',
      capabilities: { private_payments: true, payment_requests: true, receipts: true, outgoing_payments: false },
      noise_public_key: noise.publicKey.z32(),
    };
    await session.storage.putText('/pub/paykit/v0/bitkit/server/receiver.json', JSON.stringify(marker));
    console.log(JSON.stringify({ reader: reader.publicKey.z32(), marker_published: true }));
    return;
  }

  if (cmd === 'publish') {
    const [sessionToken, state] = args;
    const lockServerPubky = process.env.LOCKS_PUBLIC_KEY;
    if (!lockServerPubky) throw new Error('LOCKS_PUBLIC_KEY env required');

    const cfg = await fetch(`${LOCKS_URL}/creator/lock-service-config`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${sessionToken}` },
      body: JSON.stringify({ default_lock_server: lockServerPubky }),
    });
    if (!cfg.ok) throw new Error(`lock-service-config -> ${cfg.status}: ${await cfg.text()}`);

    const upload = await fetch(`${LOCKS_URL}/creator/priv-resources/${GUARDED_PATH}`, {
      method: 'PUT',
      headers: { 'content-type': 'text/plain', authorization: `Bearer ${sessionToken}` },
      body: `${GUARDED_BODY} ${state}`,
    });
    const uploadJson = await upload.json();
    if (!upload.ok) throw new Error(`guarded upload -> ${upload.status}: ${JSON.stringify(uploadJson)}`);

    const creator = roleZ32('CREATOR');
    const lock = await fetch(`${LOCKS_URL}/creator/content-locks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${sessionToken}` },
      body: JSON.stringify({
        primary_resource: uploadJson.guarded_resource,
        secondary_resources: {},
        criteria: [{
          criterion_id: 'criterion-1',
          verifier_type: 'paykit-payment',
          params: { recipient_pubky: creator, amount: AMOUNT, asset: ASSET },
        }],
        lock_logic: { type: 'all', criteria: ['criterion-1'] },
        access_policy: { requested_credential_ttl_seconds: 900 },
        lock_server: { override: lockServerPubky },
      }),
    });
    const lockJson = await lock.json();
    if (!lock.ok) throw new Error(`content-locks -> ${lock.status}: ${JSON.stringify(lockJson)}`);
    console.log(JSON.stringify({ creator, lock_resource: `${creator}${lockJson.content_lock_path}`, upload: uploadJson }));
    return;
  }

  if (cmd === 'negative') {
    const reader = loadKeypair('READER').publicKey.z32();
    const bundleId = randomBundleId();
    const invoiceBody = canonicalJson({ bundle_id: bundleId, lock_resource: `${reader}/pub/locks.app/x.json`, reader });
    const unsigned = await fetch(`${PAYKIT_URL}/invoices`, { method: 'POST', body: invoiceBody });
    const garbage = await fetch(`${PAYKIT_URL}/invoices`, {
      method: 'POST',
      headers: { 'X-Paykit-Signature': Buffer.alloc(64).toString('base64url') },
      body: invoiceBody,
    });
    const unsignedStatus = await fetch(`${PAYKIT_URL}/transactions/status`, {
      method: 'POST',
      body: canonicalJson({ bundle_id: bundleId, creator: reader }),
    });
    console.log(JSON.stringify({
      unsigned_invoices: unsigned.status,
      unsigned_invoices_body: await unsigned.text(),
      garbage_signed_invoices: garbage.status,
      unsigned_transactions_status: unsignedStatus.status,
    }));
    return;
  }

  if (cmd === 'proof') {
    const [lockResource, bundleId] = args;
    const reader = roleZ32('READER');
    const res = await fetch(`${LOCKS_URL}/proof-bundles`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        submitted_proof_bundle: {
          version: 1,
          bundle_id: bundleId,
          pubky_lock_resource: lockResource,
          reader_public_key: reader,
          proofs: [{ criterion_id: 'criterion-1', verifier_type: 'paykit-payment', payload: {} }],
        },
      }),
    });
    console.log(JSON.stringify({ status: res.status, body: await res.json() }));
    return;
  }

  if (cmd === 'status') {
    const bundleId = args[0];
    if (!LOCKS_SEED_B64URL) throw new Error('LOCKS_SEED_B64URL env required');
    // Canonical creator identifiers are pubky-prefixed app keys; the servers
    // reject bare z32 with invalid_request (strict canonical round-trip).
    const creator = `pubky${roleZ32('CREATOR')}`;
    const body = canonicalJson({ bundle_id: bundleId, creator });
    const seed = Buffer.from(LOCKS_SEED_B64URL, 'base64url');
    const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]);
    const key = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
    const sig = crypto.sign(null, Buffer.from(body), key).toString('base64url');
    const res = await fetch(`${PAYKIT_URL}/transactions/status`, {
      method: 'POST',
      headers: { 'X-Paykit-Signature': sig },
      body,
    });
    console.log(JSON.stringify({ status: res.status, body: await res.json() }));
    return;
  }

  if (cmd === 'lifecycle') {
    const bundleId = args[0];
    const creator = `pubky${roleZ32('CREATOR')}`;
    const res = await fetch(`${LOCKS_URL}/verification-task-lookups`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ creator, bundle_id: bundleId }),
    });
    console.log(JSON.stringify({ status: res.status, body: await res.json() }));
    return;
  }

  if (cmd === 'credential') {
    const bundleId = args[0];
    const creator = `pubky${roleZ32('CREATOR')}`;
    const res = await fetch(`${LOCKS_URL}/access-credentials`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ creator, bundle_id: bundleId }),
    });
    const json = await res.json();
    if (!res.ok) throw new Error(`access-credentials -> ${res.status}: ${JSON.stringify(json)}`);
    const read = await fetch(`${LOCKS_URL}/priv-resources/${GUARDED_PATH}`, {
      headers: { authorization: `Bearer ${json.credential}` },
    });
    const bytes = await read.text();
    console.log(JSON.stringify({ credential_status: res.status, read_status: read.status, bytes }));
    return;
  }

  if (cmd === 'checkout') {
    // Buyer-facing leg of the fiat rail: after the proof bundle triggers the
    // gateway's invoice, fetch the hosted checkout URL for this bundle. The
    // optional processor arg ("stripe" | "paypal") picks the rail while the
    // correlation is unbound; the response's `processor` field reports what
    // was actually minted (PayPal returns an approval URL, Stripe a Checkout
    // URL — both open in a browser the same way).
    const bundleId = args[0];
    if (!bundleId) throw new Error('usage: checkout <bundleId> [stripe|paypal]');
    const processor = args[1];
    const creator = `pubky${roleZ32('CREATOR')}`;
    const res = await fetch(`${FIAT_URL}/checkout-sessions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ creator, bundle_id: bundleId, ...(processor ? { processor } : {}) }),
    });
    console.log(JSON.stringify({ status: res.status, body: await res.json() }));
    return;
  }

  throw new Error(`unknown command: ${cmd}`);
}

function canonicalJson(obj) {
  return JSON.stringify(Object.fromEntries(Object.entries(obj).sort(([a], [b]) => (a < b ? -1 : 1))));
}

function randomBundleId() {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const data = crypto.randomBytes(16);
  let bits = '';
  for (const byte of data) bits += byte.toString(2).padStart(8, '0');
  let out = '';
  for (let i = 0; i < bits.length; i += 5) out += alphabet[parseInt(bits.slice(i, i + 5).padEnd(5, '0'), 2)];
  return out;
}

main().catch((error) => {
  console.error(String(error?.stack ?? error));
  process.exit(1);
});

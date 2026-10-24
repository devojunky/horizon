# Horizon's reading proxy for testers

Lets TestFlight testers read with Claude without a key of their own. A bridge until Apple's Private Cloud Compute
entitlement: once Horizon has it, reads go from the device to Apple and this Worker is switched off. So it keeps
nothing it would have to migrate: no accounts, no database of requests, only a device's public key, its assertion
counter and two running totals (DECISIONS 2026-10-23 · The tester proxy).

- **Who may read:** a genuine Horizon on a real device, proved by App Attest. An attestation registers the device's
  Secure Enclave key once (`/v1/attest`); every read then carries an assertion signed over the request's own bytes with
  a counter that only goes up (`/v1/messages`). There is no sign-in.
- **What it costs:** a daily and a monthly allowance per device, counted from each reply's own usage events in
  input-token equivalents (input 1, cache write 1.25, cache read 0.1, output 5). At most two reads per device at once.
  The hard ceiling is the Anthropic workspace's own spend limit.
- **What reaches Anthropic:** the body Horizon builds, unchanged except that the model is the server's (Sonnet 5.5),
  the output is capped and the reply always streams. Anything else (tools, other fields) is refused. Bodies are never
  logged; the log has outcomes and counts.

## Deploying

Two environments, each its own Worker with its own domain, secrets, devices and allowances:

| Environment | Domain | For | App Attest |
|---|---|---|---|
| `development` | `horizon-reading-dev.danielliang.dev` | builds run from Xcode | development |
| `production` | `horizon-reading.danielliang.dev` | TestFlight and the App Store | production |

1. Wait until danielliang.dev shows **Active** in the Cloudflare dashboard (after the nameservers change). No DNS
   records are needed: a Worker's custom domain makes its own record and certificate when it is deployed.
2. In the Claude Console, make a workspace per environment ("Horizon testers (dev)", "Horizon testers"), set each
   one's monthly spend limit, and make a key in each.
3. Sign in to Cloudflare: `pnpm install`, then `pnpm wrangler login`.
4. Set each environment's secrets (shown for development; repeat with `--env production`):
   ```bash
   pnpm wrangler secret put ANTHROPIC_API_KEY --env development
   ```
   ```bash
   openssl rand -base64 32 | pnpm wrangler secret put CHALLENGE_SECRET --env development
   ```
5. Deploy:
   ```bash
   pnpm run deploy:dev
   ```
   ```bash
   pnpm run deploy:production
   ```

There is no deploy without an environment: the top level of `wrangler.jsonc` is for `wrangler dev` and the tests,
under a name of its own (`horizon-reading-local`) and with no address.

## Working on it

```bash
pnpm test
```
```bash
pnpm typecheck
```

The tests run in workerd with the ledger as a real Durable Object. A test device signs assertions as the Secure Enclave
does; an attestation can only come from a real device, so `verifyAttestation` must be checked against one before
testers use it.

## Not done yet

- Horizon's side: `DCAppAttestService` (generate, attest, assert), the key id in the Keychain, a reading route that
  says documents go through Horizon's server to Anthropic, the App Attest entitlement, and the errors `horizon_quota`,
  `horizon_attestation`, `horizon_busy`, `horizon_unavailable` in the user's words.
- A rate limit on `/v1/challenge` and `/v1/attest`, which anyone can call (Cloudflare's rate-limiting binding).
- Apple's fraud receipt (kept, not yet used) and a way to revoke a device.

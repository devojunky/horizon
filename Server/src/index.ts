// Horizon's reading proxy for testers (DECISIONS 2026-10-23 · The tester proxy).
//
//   POST /v1/challenge   → { challenge }                    one-time, for an attestation
//   POST /v1/attest      { keyId, attestation, challenge }  App Attest: the device's key is kept
//   POST /v1/messages    the Messages API body, with        streamed through to Anthropic under the server's key,
//                        x-horizon-key-id and                within the device's allowance
//                        x-horizon-assertion headers
//
// No accounts and nothing of a request kept: the ledger holds a device's public key, its assertion counter and two
// running totals. Errors come back in the API's own shape (`{type: "error", error: {type, message}}`), with types of
// Horizon's own where the app must tell them apart: `horizon_quota` (the allowance is used up: not a 429, which the app
// retries) and `horizon_attestation` (attest again).

import { AttestError, type AttestEnvironment, verifyAttestation } from "./appattest";
import { fromBase64 } from "./bytes";
import { checkChallenge, issueChallenge } from "./challenge";
import { DeviceLedger, type Limits } from "./ledger";
import { shape } from "./shape";
import { UsageMeter } from "./usage";

export { DeviceLedger };

export interface Env {
  LEDGER: DurableObjectNamespace<DeviceLedger>;
  ANTHROPIC_API_KEY: string;
  CHALLENGE_SECRET: string;
  APP_ID: string;
  ATTEST_ENVIRONMENT: AttestEnvironment;
  MODEL: string;
  MAX_OUTPUT_TOKENS: string;
  DAILY_UNITS: string;
  MONTHLY_UNITS: string;
  ANTHROPIC_BASE_URL: string;
}

/** The API's own error shape, so the app's error mapping reads it as it reads Anthropic's. */
function failure(status: number, type: string, message: string, headers: Record<string, string> = {}): Response {
  return Response.json({ type: "error", error: { type, message } }, { status, headers });
}

function limits(env: Env): Limits {
  return { daily: Number(env.DAILY_UNITS), monthly: Number(env.MONTHLY_UNITS), concurrent: 2 };
}

export async function handle(request: Request, env: Env, ctx: ExecutionContext, upstream: typeof fetch = fetch): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (request.method !== "POST") return failure(405, "invalid_request_error", "Only POST is served here.");

  if (pathname === "/v1/challenge") return Response.json({ challenge: await issueChallenge(env.CHALLENGE_SECRET) });

  if (pathname === "/v1/attest") {
    let input: { keyId?: string; attestation?: string; challenge?: string };
    try { input = await request.json(); } catch { return failure(400, "invalid_request_error", "The request is not JSON."); }
    if (!input.keyId || !input.attestation || !input.challenge) return failure(400, "invalid_request_error", "keyId, attestation and challenge are needed.");
    const challenge = await checkChallenge(input.challenge, env.CHALLENGE_SECRET);
    if (!challenge) return failure(401, "horizon_attestation", "The challenge is not this server's, or has expired.");
    try {
      const key = await verifyAttestation(fromBase64(input.attestation), fromBase64(input.keyId), challenge, env.APP_ID, env.ATTEST_ENVIRONMENT);
      const kept = await env.LEDGER.get(env.LEDGER.idFromName(input.keyId)).register(key.publicKey, env.ATTEST_ENVIRONMENT);
      if (!kept) return failure(409, "horizon_attestation", "This key is already attested; make a new one.");
      console.log(JSON.stringify({ event: "attested", environment: env.ATTEST_ENVIRONMENT }));
      return Response.json({ ok: true });
    } catch (error) {
      const reason = error instanceof AttestError ? error.message : "unreadable";
      console.log(JSON.stringify({ event: "attestation refused", reason }));
      return failure(401, "horizon_attestation", `The attestation was refused: ${reason}.`);
    }
  }

  if (pathname === "/v1/messages") {
    const keyId = request.headers.get("x-horizon-key-id"), assertion = request.headers.get("x-horizon-assertion");
    if (!keyId || !assertion) return failure(401, "horizon_attestation", "This server reads only for an attested Horizon.");
    // The assertion is signed over the body exactly as sent, so the body is read as bytes before anything parses it.
    const bytes = new Uint8Array(await request.arrayBuffer());
    const ledger = env.LEDGER.get(env.LEDGER.idFromName(keyId));
    let assertionBytes: Uint8Array;
    try { assertionBytes = fromBase64(assertion); } catch { return failure(401, "horizon_attestation", "The assertion is unreadable."); }
    const granted = await ledger.authorize(assertionBytes, bytes, env.APP_ID, limits(env));
    if (!granted.ok) {
      console.log(JSON.stringify({ event: "refused", reason: granted.reason, detail: granted.detail }));
      switch (granted.reason) {
        case "unknown-key": return failure(401, "horizon_attestation", "This device's key is not known here; attest again.");
        case "bad-assertion": return failure(401, "horizon_attestation", "The request's assertion did not verify.");
        case "busy": return failure(409, "horizon_busy", "Another read from this device is under way.");
        case "quota": return failure(403, "horizon_quota", "This device's reading allowance is used up.", granted.resetsAt ? { "x-horizon-resets-at": granted.resetsAt } : {});
      }
    }
    const shaped = shape(new TextDecoder().decode(bytes), env.MODEL, Number(env.MAX_OUTPUT_TOKENS));
    if (!shaped.ok) {
      ctx.waitUntil(ledger.charge(granted.readId, 0));
      return failure(400, "invalid_request_error", shaped.reason);
    }

    let reply: Response;
    try {
      reply = await upstream(`${env.ANTHROPIC_BASE_URL}/v1/messages`, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "text/event-stream", "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
        body: shaped.body,
      });
    } catch {
      ctx.waitUntil(ledger.charge(granted.readId, 0));
      return failure(502, "api_error", "Anthropic could not be reached.");
    }
    if (!reply.ok || !reply.body) {
      ctx.waitUntil(ledger.charge(granted.readId, 0));
      return upstreamFailure(reply);
    }

    // Through as it arrives; the meter reads the usage events on the way, and the read is charged however it ends
    // (finished, cut off, or the device gone).
    const meter = new UsageMeter();
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const pump = (async () => {
      const reader = reply.body!.getReader(), writer = writable.getWriter();
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          meter.feed(value);
          await writer.write(value);
        }
        await writer.close();
      } catch {
        await reader.cancel().catch(() => {});
        await writer.abort().catch(() => {});
      } finally {
        await ledger.charge(granted.readId, meter.units);
        console.log(JSON.stringify({ event: "read", units: meter.units, input: meter.input, output: meter.output }));
      }
    })();
    ctx.waitUntil(pump);
    return new Response(readable, { status: 200, headers: { "content-type": "text/event-stream", "cache-control": "no-store" } });
  }

  return failure(404, "not_found_error", "Nothing is served at that path.");
}

/** Anthropic's refusals as the app should hear them: its own errors pass through, but the server's key and account are
 * not the device's to fix, so those read as the service being unavailable rather than "your key". */
async function upstreamFailure(reply: Response): Promise<Response> {
  if (reply.status === 401 || reply.status === 403 || reply.status === 402) {
    console.log(JSON.stringify({ event: "upstream refused the server", status: reply.status }));
    return failure(503, "horizon_unavailable", "Horizon's reading service is not available right now.");
  }
  const headers: Record<string, string> = { "content-type": reply.headers.get("content-type") ?? "application/json" };
  const retryAfter = reply.headers.get("retry-after");
  if (retryAfter) headers["retry-after"] = retryAfter;
  return new Response(reply.body, { status: reply.status, headers });
}

export default {
  fetch(request, env, ctx) { return handle(request, env, ctx); },
} satisfies ExportedHandler<Env>;

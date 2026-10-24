import { createExecutionContext, env as testEnv, waitOnExecutionContext } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { handle, type Env } from "../src/index";
import { TestDevice } from "./device";

const env = testEnv as unknown as Env;
const reply = [
  'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":40000,"output_tokens":1}}}\n\n',
  'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\\"outline\\":"}}\n\n',
  'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8000}}\n\n',
  'event: message_stop\ndata: {"type":"message_stop"}\n\n',
];

/** Anthropic as the tests have it: the reply above, streamed in parts, and what was sent to it. */
function anthropic(status = 200) {
  const sent: { url: string; headers: Headers; body: string }[] = [];
  const upstream = (async (url: RequestInfo | URL, init?: RequestInit) => {
    sent.push({ url: String(url), headers: new Headers(init?.headers), body: String(init?.body) });
    if (status !== 200) return Response.json({ type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }, { status });
    const parts = reply.map((part) => new TextEncoder().encode(part));
    return new Response(new ReadableStream({ pull(controller) { const next = parts.shift(); next ? controller.enqueue(next) : controller.close(); } }), { headers: { "content-type": "text/event-stream" } });
  }) as typeof fetch;
  return { upstream, sent };
}

async function attestedDevice(): Promise<TestDevice> {
  const device = await TestDevice.make(env.APP_ID);
  // The attestation itself needs a real device; its outcome, the key kept, is what the ledger works from.
  expect(await env.LEDGER.get(env.LEDGER.idFromName(device.keyId)).register(device.publicKey, "development")).toBe(true);
  return device;
}

async function read(device: TestDevice, body: string, options: { env?: Env; upstream?: typeof fetch; assertion?: string } = {}) {
  const ctx = createExecutionContext();
  const request = new Request("https://reading.example/v1/messages", {
    method: "POST", body,
    headers: { "x-horizon-key-id": device.keyId, "x-horizon-assertion": options.assertion ?? (await device.assert(body)) },
  });
  const response = await handle(request, options.env ?? env, ctx, options.upstream ?? anthropic().upstream);
  const text = await response.text();
  await waitOnExecutionContext(ctx);
  return { response, text };
}

const body = JSON.stringify({ model: "claude-opus-5-5", max_tokens: 64000, stream: true, messages: [{ role: "user", content: "Read this syllabus." }] });

describe("a read through the proxy", () => {
  it("streams Anthropic's reply through untouched, under the server's key and model, and charges the device", async () => {
    const device = await attestedDevice();
    const { upstream, sent } = anthropic();
    const { response, text } = await read(device, body, { upstream });
    expect(response.status).toBe(200);
    expect(text).toBe(reply.join(""));
    expect(sent[0].headers.get("x-api-key")).toBe("sk-ant-test");
    expect(JSON.parse(sent[0].body)).toMatchObject({ model: env.MODEL, max_tokens: Number(env.MAX_OUTPUT_TOKENS), stream: true });
    const spend = await env.LEDGER.get(env.LEDGER.idFromName(device.keyId)).charge("none", 0);
    expect(spend.dayUnits).toBe(40000 + 8000 * 5);
  });

  it("refuses a device it does not know, a replayed assertion, and one over another body", async () => {
    const stranger = await TestDevice.make(env.APP_ID);
    const unknown = await read(stranger, body);
    expect([unknown.response.status, JSON.parse(unknown.text).error.type]).toEqual([401, "horizon_unknown_key"]);   // attest a new key

    const device = await attestedDevice();
    const assertion = await device.assert(body);
    expect((await read(device, body, { assertion })).response.status).toBe(200);
    const replayed = await read(device, body, { assertion });
    expect([replayed.response.status, JSON.parse(replayed.text).error.type]).toEqual([401, "horizon_attestation"]);
    expect((await read(device, body.replace("syllabus", "schedule"), { assertion: await device.assert(body) })).response.status).toBe(401);
  });

  it("stops a device at its allowance with Horizon's own error, never a 429", async () => {
    const device = await attestedDevice();
    const tight = { ...env, DAILY_UNITS: "50000" };
    expect((await read(device, body, { env: tight })).response.status).toBe(200);   // under the line when it starts
    const { response, text } = await read(device, body, { env: tight });
    expect([response.status, JSON.parse(text).error.type]).toEqual([403, "horizon_quota"]);
    expect(response.headers.get("x-horizon-resets-at")).toMatch(/T00:00:00/);
  });

  it("says the service is unavailable when Anthropic refuses the server's own key", async () => {
    const device = await attestedDevice();
    const { response, text } = await read(device, body, { upstream: anthropic(401).upstream });
    expect([response.status, JSON.parse(text).error.type]).toEqual([503, "horizon_unavailable"]);
  });

  it("refuses fields Horizon's reading request never sends, before anything reaches Anthropic", async () => {
    const device = await attestedDevice();
    const { upstream, sent } = anthropic();
    const withTools = JSON.stringify({ ...JSON.parse(body), tools: [{ name: "x" }] });
    expect((await read(device, withTools, { upstream })).response.status).toBe(400);
    expect(sent.length).toBe(0);
  });
});

describe("challenges and attestations", () => {
  it("hands out a challenge and refuses an attestation that is not Apple's", async () => {
    const ctx = createExecutionContext();
    const { challenge } = await (await handle(new Request("https://reading.example/v1/challenge", { method: "POST" }), env, ctx)).json<{ challenge: string }>();
    const attest = await handle(new Request("https://reading.example/v1/attest", { method: "POST", body: JSON.stringify({ keyId: "AAAA", attestation: "aGVsbG8=", challenge }) }), env, ctx);
    expect([attest.status, (await attest.json<{ error: { type: string } }>()).error.type]).toEqual([401, "horizon_attestation"]);
    const stale = await handle(new Request("https://reading.example/v1/attest", { method: "POST", body: JSON.stringify({ keyId: "AAAA", attestation: "aGVsbG8=", challenge: "AAAA" }) }), env, ctx);
    expect(stale.status).toBe(401);
  });
});

describe("rate limits", () => {
  it("hold the open endpoints to ten a minute from one address, and reads to thirty a minute from one device", async () => {
    const ctx = createExecutionContext();
    const challenge = (ip: string) => handle(new Request("https://reading.example/v1/challenge", { method: "POST", headers: { "cf-connecting-ip": ip } }), env, ctx);
    const statuses = [];
    for (let i = 0; i < 11; i++) statuses.push((await challenge("203.0.113.7")).status);
    expect(statuses.slice(0, 10).every((s) => s === 200)).toBe(true);
    const limited = await challenge("203.0.113.7");
    expect([limited.status, limited.headers.get("retry-after"), (await limited.json<{ error: { type: string } }>()).error.type]).toEqual([429, "60", "rate_limit_error"]);
    expect((await challenge("198.51.100.20")).status).toBe(200);   // another address is its own

    const device = await attestedDevice();
    const reads: number[] = [];
    for (let i = 0; i < 31; i++) reads.push((await read(device, body)).response.status);
    expect(reads.slice(0, 30).filter((s) => s === 429).length).toBe(0);
    expect(reads[30]).toBe(429);
  });
});


import { describe, expect, it } from "vitest";
import { encode } from "cbor-x";
import { AttestError, rawSignature, takesEvidence, verifyAssertion, verifyAttestation } from "../src/appattest";
import { concat, fromBase64, toBase64 } from "../src/bytes";
import { checkChallenge, issueChallenge } from "../src/challenge";
import { shape } from "../src/shape";
import { UsageMeter } from "../src/usage";
import { TestDevice } from "./device";

const appId = "M29Z3F2B5D.com.daniel.horizon.app";
const secret = "dGVzdC1zZWNyZXQtdGVzdC1zZWNyZXQtdGVzdC1zZWNyZXQ=";

describe("assertions", () => {
  it("verify over the request's own bytes, once, for this app only", async () => {
    const device = await TestDevice.make(appId);
    const body = '{"messages":[]}';
    const assertion = fromBase64(await device.assert(body));
    expect(await verifyAssertion(assertion, new TextEncoder().encode(body), device.publicKey, appId, 0)).toBe(1);
    // The same assertion again: its counter has not advanced.
    await expect(verifyAssertion(assertion, new TextEncoder().encode(body), device.publicKey, appId, 1)).rejects.toThrow("counter did not advance");
    // Another body under the same assertion: the signature is over the bytes.
    await expect(verifyAssertion(assertion, new TextEncoder().encode('{"messages":[1]}'), device.publicKey, appId, 0)).rejects.toThrow("signature does not verify");
    // Another app's assertion.
    const other = fromBase64(await device.assert(body, 5, "M29Z3F2B5D.com.other.app"));
    await expect(verifyAssertion(other, new TextEncoder().encode(body), device.publicKey, appId, 0)).rejects.toThrow("asserted for another app");
    // Another key.
    const stranger = await TestDevice.make(appId);
    await expect(verifyAssertion(fromBase64(await stranger.assert(body)), new TextEncoder().encode(body), device.publicKey, appId, 0)).rejects.toThrow("signature does not verify");
  });

  it("read a DER signature with a sign byte as 64 raw bytes", () => {
    const r = new Uint8Array(32).fill(0x81), s = new Uint8Array(32).fill(0x01);
    const der = new Uint8Array([0x30, 69, 0x02, 33, 0, ...r, 0x02, 32, ...s]);
    expect(Array.from(rawSignature(der))).toEqual([...r, ...s]);
  });
});

describe("attestations", () => {
  it("refuse what is not Apple's App Attest", async () => {
    const challenge = new Uint8Array(56);
    await expect(verifyAttestation(new TextEncoder().encode("hello"), new Uint8Array(32), challenge, appId, "development")).rejects.toBeInstanceOf(AttestError);
    await expect(verifyAttestation(encode({ fmt: "packed", attStmt: {}, authData: new Uint8Array(40) }), new Uint8Array(32), challenge, appId, "development"))
      .rejects.toThrow("not an App Attest attestation");
  });

  it("take production's evidence in development too, as a Mac's always is, and never development's in production", () => {
    const development = new TextEncoder().encode("appattestdevelop"), production = concat(new TextEncoder().encode("appattest"), new Uint8Array(7));
    expect(takesEvidence("development", development)).toBe(true);
    expect(takesEvidence("development", production)).toBe(true);
    expect(takesEvidence("production", production)).toBe(true);
    expect(takesEvidence("production", development)).toBe(false);
    expect(takesEvidence("development", new Uint8Array(16))).toBe(false);
  });
});

describe("challenges", () => {
  it("are good for five minutes and from this server only", async () => {
    const now = Date.now();
    const challenge = await issueChallenge(secret, now);
    expect(await checkChallenge(challenge, secret, now + 60_000)).not.toBeNull();
    expect(await checkChallenge(challenge, secret, now + 6 * 60_000)).toBeNull();
    expect(await checkChallenge(challenge, toBase64(new Uint8Array(32).fill(7)), now)).toBeNull();
    expect(await checkChallenge("not-a-challenge", secret, now)).toBeNull();
  });
});

describe("the usage meter", () => {
  it("reads the input and the last output total, across chunk boundaries", () => {
    const meter = new UsageMeter();
    const stream = [
      'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":2000,"output_tokens":1}}}\n\n',
      'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"text":"the word usage in a reply"}}\n\n',
      'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":',
      '300}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n',
    ];
    for (const part of stream) meter.feed(new TextEncoder().encode(part));
    expect([meter.input, meter.cacheRead, meter.output]).toEqual([1000, 2000, 300]);
    expect(meter.units).toBe(1000 + 200 + 1500);
  });
});

describe("shaping a request", () => {
  const request = (fields: Record<string, unknown>) => JSON.stringify({ model: "claude-opus-5-5", max_tokens: 99999, messages: [{ role: "user", content: "x" }], ...fields });

  it("takes the server's model, caps the output, streams, and keeps the schema's order", () => {
    const schema = { type: "object", properties: { outline: {}, course: {}, obligations: {} } };
    const shaped = shape(request({ output_config: { format: { type: "json_schema", schema } }, thinking: { type: "disabled" } }), "claude-sonnet-5-5", 32000);
    expect(shaped.ok).toBe(true);
    if (!shaped.ok) return;
    const body = JSON.parse(shaped.body);
    expect([body.model, body.max_tokens, body.stream, body.thinking.type]).toEqual(["claude-sonnet-5-5", 32000, true, "between_tools"]);
    expect(Object.keys(body.output_config.format.schema.properties)).toEqual(["outline", "course", "obligations"]);
  });

  it("refuses what Horizon's reading request never sends", () => {
    expect(shape(request({ tools: [] }), "claude-sonnet-5-5", 32000)).toEqual({ ok: false, reason: '"tools" is not accepted here.' });
    expect(shape(request({ thinking: { type: "enabled", budget_tokens: 9000 } }), "claude-sonnet-5-5", 32000).ok).toBe(false);
    expect(shape("[]", "claude-sonnet-5-5", 32000).ok).toBe(false);
    expect(shape('{"messages":[]}', "claude-sonnet-5-5", 32000).ok).toBe(false);
  });
});

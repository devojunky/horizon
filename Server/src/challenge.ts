// The one-time challenge an attestation is made over. Stateless: the time and 16 random bytes, signed with the
// server's secret, good for five minutes. A replayed attestation can only register a key that is already registered,
// which the ledger refuses.

import { concat, equal, fromBase64, toBase64URL } from "./bytes";

const lifetime = 5 * 60 * 1000;

async function mac(secret: string, data: Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", fromBase64(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
}

export async function issueChallenge(secret: string, now = Date.now()): Promise<string> {
  const body = new Uint8Array(24);
  new DataView(body.buffer).setBigUint64(0, BigInt(now));
  crypto.getRandomValues(body.subarray(8));
  return toBase64URL(concat(body, await mac(secret, body)));
}

/** The challenge's bytes when it is ours and still fresh, else nil. */
export async function checkChallenge(challenge: string, secret: string, now = Date.now()): Promise<Uint8Array | null> {
  let bytes: Uint8Array;
  try { bytes = fromBase64(challenge); } catch { return null; }
  if (bytes.length !== 56) return null;
  const body = bytes.subarray(0, 24);
  if (!equal(bytes.subarray(24), await mac(secret, body))) return null;
  const issued = Number(new DataView(body.buffer, body.byteOffset).getBigUint64(0));
  return now - issued >= 0 && now - issued <= lifetime ? bytes : null;
}

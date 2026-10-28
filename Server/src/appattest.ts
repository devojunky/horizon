// App Attest, as Apple documents it ("Validating apps that connect to your server"): an attestation once per device
// key, proving the key lives in the Secure Enclave of a genuine device running this app; then an assertion with
// every request, signed by that key over the request's own bytes, with a counter that only goes up.

import "reflect-metadata";   // @peculiar/x509 resolves its parsers through tsyringe, which needs it loaded first
import { X509Certificate } from "@peculiar/x509";
import { decode } from "cbor-x";
import { appleAppAttestationRootCA } from "./appleRoot";
import { concat, equal, sha256 } from "./bytes";

export type AttestEnvironment = "development" | "production";

export class AttestError extends Error {}

/** What the server keeps of a device's key once its attestation checks out. */
export interface AttestedKey {
  /** The key's public half, uncompressed P-256 (65 bytes). */
  publicKey: Uint8Array;
  /** Apple's receipt, for fraud-metric checks later; unused for now. */
  receipt: Uint8Array;
}

const nonceExtension = "1.2.840.113635.100.8.2";
const aaguids: Record<AttestEnvironment, Uint8Array> = {
  development: new TextEncoder().encode("appattestdevelop"),
  production: concat(new TextEncoder().encode("appattest"), new Uint8Array(7)),
};

/** Whether a service in `environment` takes evidence with this AAGUID: production takes production's alone; development
 * takes production's too, because a Mac's evidence names production whatever its build (macOS 27 has no development
 * environment for App Attest, and Xcode signs the Mac without the entitlement for one), and a Mac's Debug build talks to
 * the development service. Production evidence comes from a genuine build of this app as surely as development's does. */
export function takesEvidence(environment: AttestEnvironment, aaguid: Uint8Array): boolean {
  const taken: AttestEnvironment[] = environment === "development" ? ["development", "production"] : ["production"];
  return taken.some((each) => equal(aaguid, aaguids[each]));
}

/** The fields of authenticator data App Attest uses: rpIdHash 32, flags 1, counter 4, then for an attestation the
 * AAGUID 16, the credential id's length 2 and the credential id. */
function authenticatorData(data: Uint8Array, withCredential: boolean) {
  if (data.length < 37) throw new AttestError("authenticator data too short");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const parsed: { rpIdHash: Uint8Array; counter: number; aaguid: Uint8Array; credentialId: Uint8Array } =
    { rpIdHash: data.subarray(0, 32), counter: view.getUint32(33), aaguid: new Uint8Array(), credentialId: new Uint8Array() };
  if (withCredential) {
    if (data.length < 55) throw new AttestError("authenticator data has no credential");
    const length = view.getUint16(53);
    if (data.length < 55 + length) throw new AttestError("credential id cut short");
    parsed.aaguid = data.subarray(37, 53);
    parsed.credentialId = data.subarray(55, 55 + length);
  }
  return parsed;
}

/** The nonce Apple writes into the credential certificate's extension: DER `SEQUENCE { [1] { OCTET STRING } }`. */
function nonceIn(extension: Uint8Array): Uint8Array {
  let at = 0;
  const header = (tag: number) => {
    if (extension[at++] !== tag) throw new AttestError("nonce extension malformed");
    let length = extension[at++];
    if (length & 0x80) {
      const bytes = length & 0x7f;
      length = 0;
      for (let i = 0; i < bytes; i++) length = (length << 8) | extension[at++];
    }
    return length;
  };
  header(0x30);
  header(0xa1);
  const length = header(0x04);
  return extension.subarray(at, at + length);
}

async function rawPublicKey(certificate: X509Certificate): Promise<Uint8Array> {
  const key = await certificate.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  return new Uint8Array((await crypto.subtle.exportKey("raw", key)) as ArrayBuffer);
}

/** Checks an attestation for `keyId` made over `challenge`, and returns the key to keep. Every step Apple lists. */
export async function verifyAttestation(attestation: Uint8Array, keyId: Uint8Array, challenge: Uint8Array,
                                        appId: string, environment: AttestEnvironment, now = new Date()): Promise<AttestedKey> {
  let object: { fmt?: string; attStmt?: { x5c?: Uint8Array[]; receipt?: Uint8Array }; authData?: Uint8Array };
  try { object = decode(attestation); } catch { throw new AttestError("not CBOR"); }
  if (object?.fmt !== "apple-appattest" || !object.attStmt?.x5c?.length || !object.authData) throw new AttestError("not an App Attest attestation");

  // 1. The certificates chain to Apple's App Attestation root, each valid now.
  const [credential, ...intermediates] = object.attStmt.x5c.map((der) => new X509Certificate(der));
  const root = new X509Certificate(appleAppAttestationRootCA);
  const chain = [credential, ...intermediates, root];
  for (let i = 0; i < chain.length - 1; i++) {
    if (!(await chain[i].verify({ publicKey: chain[i + 1].publicKey, date: now }))) throw new AttestError("certificate chain does not verify");
  }
  if (!(await root.verify({ date: now }))) throw new AttestError("root out of date");

  // 2–4. The nonce in the credential certificate is SHA-256(authData ‖ SHA-256(challenge)).
  const nonce = await sha256(concat(object.authData, await sha256(challenge)));
  const extension = credential.getExtension(nonceExtension);
  if (!extension || !equal(nonceIn(new Uint8Array(extension.value)), nonce)) throw new AttestError("nonce does not match");

  // 5. The key id is the SHA-256 of the credential certificate's public key.
  const publicKey = await rawPublicKey(credential);
  if (!equal(await sha256(publicKey), keyId)) throw new AttestError("key id does not match the certificate");

  // 6–9. The authenticator data names this app, starts the counter at 0, says which environment, and carries the key id.
  const data = authenticatorData(object.authData, true);
  if (!equal(data.rpIdHash, await sha256(appId))) throw new AttestError("attested for another app");
  if (data.counter !== 0) throw new AttestError("counter is not 0");
  if (!takesEvidence(environment, data.aaguid)) throw new AttestError(`not a ${environment} attestation`);
  if (!equal(data.credentialId, keyId)) throw new AttestError("credential id does not match the key id");

  return { publicKey, receipt: object.attStmt.receipt ?? new Uint8Array() };
}

/** A DER ECDSA signature as the 64 raw bytes WebCrypto wants. */
export function rawSignature(der: Uint8Array): Uint8Array {
  if (der[0] !== 0x30) throw new AttestError("signature is not DER");
  let at = 2;
  const integer = () => {
    if (der[at++] !== 0x02) throw new AttestError("signature is not DER");
    const length = der[at++];
    let value = der.subarray(at, at + length);
    at += length;
    while (value.length > 32 && value[0] === 0) value = value.subarray(1);
    if (value.length > 32) throw new AttestError("signature integer too long");
    return concat(new Uint8Array(32 - value.length), value);
  };
  return concat(integer(), integer());
}

/** Checks an assertion over `clientData` (the request's own bytes) with the device's kept key, and returns its
 * counter, which must be above the last one seen. */
export async function verifyAssertion(assertion: Uint8Array, clientData: Uint8Array, publicKey: Uint8Array,
                                      appId: string, lastCounter: number): Promise<number> {
  let object: { signature?: Uint8Array; authenticatorData?: Uint8Array };
  try { object = decode(assertion); } catch { throw new AttestError("not CBOR"); }
  if (!object?.signature || !object.authenticatorData) throw new AttestError("not an App Attest assertion");

  // 1–3. The signature is ECDSA P-256 with SHA-256 over SHA-256(authenticatorData ‖ SHA-256(clientData)).
  const nonce = await sha256(concat(object.authenticatorData, await sha256(clientData)));
  const key = await crypto.subtle.importKey("raw", publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, rawSignature(object.signature), nonce);
  if (!valid) throw new AttestError("signature does not verify");

  // 4–5. This app, and a counter above the last: an assertion is good once.
  const data = authenticatorData(object.authenticatorData, false);
  if (!equal(data.rpIdHash, await sha256(appId))) throw new AttestError("asserted for another app");
  if (data.counter <= lastCounter) throw new AttestError("counter did not advance");
  return data.counter;
}

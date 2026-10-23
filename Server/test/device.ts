// A stand-in for a device's App Attest key: a P-256 key made here, signing assertions exactly as the Secure Enclave
// does (ECDSA SHA-256 over SHA-256(authenticatorData ‖ SHA-256(clientData)), DER, in CBOR). An attestation cannot be
// made this way (Apple signs its certificate chain), so those are checked against a real device before release.

import { encode } from "cbor-x";
import { concat, sha256, toBase64 } from "../src/bytes";

export class TestDevice {
  private constructor(private keys: CryptoKeyPair, readonly publicKey: Uint8Array, readonly keyId: string, private appId: string) {}
  counter = 0;

  static async make(appId: string): Promise<TestDevice> {
    const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const publicKey = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
    return new TestDevice(keys, publicKey, toBase64(await sha256(publicKey)), appId);
  }

  /** An assertion over `clientData`, with the next counter (or the one given, to replay or go backwards). */
  async assert(clientData: Uint8Array | string, counter = ++this.counter, appId = this.appId): Promise<string> {
    const data = typeof clientData === "string" ? new TextEncoder().encode(clientData) : clientData;
    const counterBytes = new Uint8Array(4);
    new DataView(counterBytes.buffer).setUint32(0, counter);
    const authenticatorData = concat(await sha256(appId), new Uint8Array([0x40]), counterBytes);
    const nonce = await sha256(concat(authenticatorData, await sha256(data)));
    const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.keys.privateKey, nonce));
    return toBase64(encode({ signature: der(raw), authenticatorData }));
  }
}

function der(raw: Uint8Array): Uint8Array {
  const integer = (bytes: Uint8Array) => {
    let at = 0;
    while (at < bytes.length - 1 && bytes[at] === 0) at++;
    let value = bytes.subarray(at);
    if (value[0] & 0x80) value = concat(new Uint8Array([0]), value);
    return concat(new Uint8Array([0x02, value.length]), value);
  };
  const body = concat(integer(raw.subarray(0, 32)), integer(raw.subarray(32)));
  return concat(new Uint8Array([0x30, body.length]), body);
}

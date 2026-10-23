// One Durable Object per attested device key: its public key, the last assertion counter, what it has spent today and
// this month, and the reads under way. A Durable Object runs one request at a time, so a counter can never be accepted
// twice and two reads can never both take the last of an allowance.

import { DurableObject } from "cloudflare:workers";
import { AttestError, verifyAssertion } from "./appattest";

export interface Limits { daily: number; monthly: number; concurrent: number }

export type Authorization =
  | { ok: true; readId: string; remainingToday: number }
  | { ok: false; reason: "unknown-key" | "bad-assertion" | "quota" | "busy"; detail?: string; resetsAt?: string };

interface Spend { day: string; dayUnits: number; month: string; monthUnits: number }

/** A read that never reported back (the Worker was stopped mid-stream) stops counting as under way after this. */
const staleRead = 15 * 60 * 1000;

export class DeviceLedger extends DurableObject {
  /** Keeps a key from an attestation. A key already kept is refused: an attestation is good once. */
  async register(publicKey: Uint8Array, environment: string, now = Date.now()): Promise<boolean> {
    if (await this.ctx.storage.get("publicKey")) return false;
    await this.ctx.storage.put({ publicKey, environment, counter: 0, registeredAt: now });
    return true;
  }

  /** Checks a request's assertion and the device's allowance, and marks a read under way. */
  async authorize(assertion: Uint8Array, clientData: Uint8Array, appId: string, limits: Limits, now = Date.now()): Promise<Authorization> {
    return this.ctx.blockConcurrencyWhile(async () => {
      const publicKey = await this.ctx.storage.get<Uint8Array>("publicKey");
      if (!publicKey) return { ok: false, reason: "unknown-key" } as const;
      const last = (await this.ctx.storage.get<number>("counter")) ?? 0;
      let counter: number;
      try { counter = await verifyAssertion(assertion, clientData, publicKey, appId, last); }
      catch (error) { return { ok: false, reason: "bad-assertion", detail: error instanceof AttestError ? error.message : "unreadable" } as const; }
      await this.ctx.storage.put("counter", counter);

      const spend = await this.spend(now);
      if (spend.dayUnits >= limits.daily) return { ok: false, reason: "quota", resetsAt: nextDay(now) } as const;
      if (spend.monthUnits >= limits.monthly) return { ok: false, reason: "quota", resetsAt: nextMonth(now) } as const;
      const reads = ((await this.ctx.storage.get<Record<string, number>>("reads")) ?? {});
      for (const [id, started] of Object.entries(reads)) if (now - started > staleRead) delete reads[id];
      if (Object.keys(reads).length >= limits.concurrent) return { ok: false, reason: "busy" } as const;
      const readId = crypto.randomUUID();
      reads[readId] = now;
      await this.ctx.storage.put("reads", reads);
      return { ok: true, readId, remainingToday: limits.daily - spend.dayUnits } as const;
    });
  }

  /** Adds what a read cost, however it ended, and takes it off the reads under way. */
  async charge(readId: string, units: number, now = Date.now()): Promise<Spend> {
    const spend = await this.spend(now);
    spend.dayUnits += units;
    spend.monthUnits += units;
    const reads = ((await this.ctx.storage.get<Record<string, number>>("reads")) ?? {});
    delete reads[readId];
    await this.ctx.storage.put({ spend, reads });
    return spend;
  }

  /** Today's and this month's spend, started afresh when the day or the month (UTC) has turned. */
  private async spend(now: number): Promise<Spend> {
    const stored = await this.ctx.storage.get<Spend>("spend");
    const day = new Date(now).toISOString().slice(0, 10), month = day.slice(0, 7);
    return {
      day, month,
      dayUnits: stored?.day === day ? stored.dayUnits : 0,
      monthUnits: stored?.month === month ? stored.monthUnits : 0,
    };
  }
}

function nextDay(now: number): string {
  const d = new Date(now);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1)).toISOString();
}

function nextMonth(now: number): string {
  const d = new Date(now);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)).toISOString();
}

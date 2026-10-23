// What a streamed reply cost, read from the reply itself as it passes: `message_start` carries the input (and the
// cache's share of it), `message_delta` the output so far. Nothing else of the stream is looked at or kept.

/** Input-token equivalents at Sonnet 5.5's prices: input 1, cache write 1.25, cache read 0.1, output 5. */
export const weights = { input: 1, cacheWrite: 1.25, cacheRead: 0.1, output: 5 };

export class UsageMeter {
  input = 0;
  cacheWrite = 0;
  cacheRead = 0;
  output = 0;
  private pending = "";
  private decoder = new TextDecoder();

  feed(chunk: Uint8Array): void {
    this.pending += this.decoder.decode(chunk, { stream: true });
    // Events end in line feeds; a line still being written waits for the next chunk.
    let end: number;
    while ((end = this.pending.indexOf("\n")) >= 0) {
      const line = this.pending.slice(0, end);
      this.pending = this.pending.slice(end + 1);
      if (line.startsWith("data:") && line.includes("usage")) this.read(line.slice(5).trim());
    }
  }

  private read(json: string): void {
    let event: { type?: string; message?: { usage?: Usage }; usage?: Usage };
    try { event = JSON.parse(json); } catch { return; }
    const usage = event.type === "message_start" ? event.message?.usage : event.type === "message_delta" ? event.usage : undefined;
    if (!usage) return;
    if (event.type === "message_start") {
      this.input = usage.input_tokens ?? 0;
      this.cacheWrite = usage.cache_creation_input_tokens ?? 0;
      this.cacheRead = usage.cache_read_input_tokens ?? 0;
    }
    // Cumulative in each delta: the last one seen is the total.
    if (usage.output_tokens !== undefined) this.output = usage.output_tokens;
  }

  get units(): number {
    return Math.ceil(this.input * weights.input + this.cacheWrite * weights.cacheWrite + this.cacheRead * weights.cacheRead + this.output * weights.output);
  }
}

interface Usage {
  input_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
  output_tokens?: number;
}

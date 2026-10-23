// What a tester's request may ask of the API: the reading request Horizon builds (`ClaudeClient.makeRequest`), and
// nothing else. The model is the server's, the output is capped, the reply always streams. Anything more (tools, a
// batch, another endpoint's fields) is refused rather than passed on: the key is the server's, not the device's.
//
// JSON.parse and JSON.stringify keep string keys in the order written, so the schema's property order (which the API
// enforces on structured output, and which Horizon writes by hand for that reason) arrives as the app wrote it.

const accepted = new Set(["model", "max_tokens", "stream", "system", "messages", "output_config", "thinking"]);
const thinkingTypes = new Set(["adaptive", "between_tools", "disabled"]);

export type Shaped = { ok: true; body: string } | { ok: false; reason: string };

export function shape(text: string, model: string, maxOutputTokens: number): Shaped {
  let body: Record<string, unknown>;
  try { body = JSON.parse(text); } catch { return { ok: false, reason: "The request is not JSON." }; }
  if (!body || typeof body !== "object" || Array.isArray(body)) return { ok: false, reason: "The request is not an object." };
  for (const key of Object.keys(body)) if (!accepted.has(key)) return { ok: false, reason: `"${key}" is not accepted here.` };
  if (!Array.isArray(body.messages) || body.messages.length === 0) return { ok: false, reason: "The request has no messages." };
  const thinking = body.thinking as { type?: string } | undefined;
  if (thinking !== undefined && !(thinking && thinkingTypes.has(thinking.type ?? ""))) return { ok: false, reason: "That thinking setting is not accepted here." };
  const asked = typeof body.max_tokens === "number" && body.max_tokens > 0 ? body.max_tokens : maxOutputTokens;
  // The app chose the thinking setting for its own model; Sonnet 5.5 turns thinking off with `between_tools` and
  // refuses `disabled` (DECISIONS 2026-10-22).
  if (thinking?.type === "disabled" && model.startsWith("claude-sonnet-5-5")) body.thinking = { type: "between_tools" };
  body.model = model;
  body.max_tokens = Math.min(asked, maxOutputTokens);
  body.stream = true;
  return { ok: true, body: JSON.stringify(body) };
}

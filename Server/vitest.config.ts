import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// The tests run in workerd, the Workers runtime itself, with the ledger as a real Durable Object. Test-only secrets.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: { bindings: { ANTHROPIC_API_KEY: "sk-ant-test", CHALLENGE_SECRET: "dGVzdC1zZWNyZXQtdGVzdC1zZWNyZXQtdGVzdC1zZWNyZXQ=" } },
    }),
  ],
});

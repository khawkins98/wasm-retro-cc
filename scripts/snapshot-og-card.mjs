#!/usr/bin/env node
/*
 * snapshot-og-card.mjs — capture web-demo/og-card.png from the live
 * static demo page. The OG image needs refreshing every time the
 * demo's visible chrome changes (new layout, copy rewrite, etc.) so
 * the social-share previews stay current.
 *
 * Usage:
 *   1. Serve the demo locally:
 *        cd web-demo && python3 -m http.server 8765
 *   2. In another shell:
 *        node scripts/snapshot-og-card.mjs            # default port 8765
 *        node scripts/snapshot-og-card.mjs --port 8888
 *
 * Dependencies: Playwright. We don't have it as a wasm-retro-cc dep,
 * so this script reuses the Playwright install from the sibling
 * classic-vibe-mac checkout if present (the demo is a single static
 * page and shouldn't drag in a heavy test dep). Override with
 * --playwright /path/to/playwright/index.mjs if your layout differs.
 *
 * Output: web-demo/og-card.png at 1200x630 @ 1.5x device pixels.
 */
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, "..");
const OUT = resolve(REPO, "web-demo/og-card.png");

const args = process.argv.slice(2);
function flag(name, def) {
  const i = args.indexOf("--" + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
}
const port = flag("port", "8765");
const playwrightPath = flag(
  "playwright",
  resolve(REPO, "../classic-vibe-mac/node_modules/playwright/index.mjs"),
);
if (!existsSync(playwrightPath)) {
  console.error(
    `Could not find Playwright at ${playwrightPath}. Pass --playwright ` +
      `/path/to/playwright/index.mjs to override.`,
  );
  process.exit(1);
}

const { chromium } = await import(playwrightPath);
const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1200, height: 630 },
  deviceScaleFactor: 1.5,
});
const page = await ctx.newPage();
const url = `http://localhost:${port}/`;
console.log(`fetching ${url}…`);
await page.goto(url, { waitUntil: "domcontentloaded" });
// Let fonts + CSS settle.
await page.waitForTimeout(1500);
await page.screenshot({ path: OUT });
await browser.close();

console.log(`wrote ${OUT}`);

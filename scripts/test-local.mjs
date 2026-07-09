// Minimal on-device acceptance: reads mcp-config.json for the exact env/paths
// the MCP server will use, launches the signed chromium once via
// playwright-core, loads a page, screenshots it.
// Run as:  node ~/.playwright-ohos/test-local.mjs
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const cfg = JSON.parse(readFileSync(new URL('mcp-config.json', import.meta.url), 'utf8'));
for (const [k, v] of Object.entries(cfg.env)) if (v) process.env[k] = v;

// same platform fix the MCP launcher applies via --require shim.cjs
if (process.platform !== 'linux') {
  Object.defineProperty(process, 'platform', { value: 'linux' });
}

const require = createRequire(new URL('mcp/package.json', import.meta.url));
const { chromium } = require('playwright-core');

const exe = cfg.args[cfg.args.indexOf('--executable-path') + 1];
console.log('launching:', exe);
const browser = await chromium.launch({
  executablePath: exe,
  headless: true,
  args: ['--no-sandbox'],
});
console.log('chromium:', browser.version());
const page = await browser.newPage();
await page.goto('data:text/html,<title>ohos-ok</title><h1>本机验收</h1>');
console.log('title:', await page.title());
const shot = new URL('output/local-shot.png', import.meta.url).pathname;
await page.screenshot({ path: shot });
console.log('screenshot:', shot);
await browser.close();
console.log('LOCAL OK');

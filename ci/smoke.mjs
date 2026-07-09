import { chromium } from 'playwright-core';
import http from 'node:http';
import fs from 'node:fs';

const exe = process.argv[2];
if (!exe) throw new Error('usage: node smoke.mjs <chrome-path>');

const browser = await chromium.launch({
  executablePath: exe,
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
});
console.log('chromium:', browser.version());

const ctx = await browser.newContext({ viewport: { width: 800, height: 600 } });
const page = await ctx.newPage();

await page.goto('data:text/html,<title>ok-ohos</title><h1 style="font-size:40px">你好 OHOS</h1>');
if ((await page.title()) !== 'ok-ohos') throw new Error('title mismatch');
console.log('data: URL ok; eval 7*6 =', await page.evaluate('7*6'));

const server = http.createServer((req, res) => {
  res.setHeader('content-type', 'text/html');
  res.end('<title>net-ok</title><p>served from node</p>');
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
await page.goto(`http://127.0.0.1:${port}/`);
if ((await page.title()) !== 'net-ok') throw new Error('local http failed');
console.log('local http ok');

await page.screenshot({ path: '/smoke/out/shot.png' });
const sz = fs.statSync('/smoke/out/shot.png').size;
console.log('screenshot bytes:', sz);
if (sz < 1000) throw new Error('screenshot suspiciously small');

server.close();
await browser.close();
console.log('playwright-core smoke OK');

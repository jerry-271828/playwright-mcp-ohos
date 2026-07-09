// Drives @playwright/mcp over stdio with the exact argv/env contract the
// device launcher (mcp-config.json) uses, so a green run here means the
// device config is protocol-valid too.
import { spawn } from 'node:child_process';

const exe = process.argv[2];
if (!exe) throw new Error('usage: node smoke-mcp.mjs <chrome-path>');

const args = [
  '--require', '/w/scripts/shim.cjs',
  'node_modules/@playwright/mcp/cli.js',
  '--browser', 'chromium',
  '--executable-path', exe,
  '--headless',
  '--no-sandbox',
  '--isolated',
  '--output-dir', '/smoke/out',
];
console.log('spawning: node', args.join(' '));
const child = spawn('node', args, { stdio: ['pipe', 'pipe', 'inherit'], cwd: '/smoke' });
child.on('exit', (code, sig) => console.log(`mcp server exited code=${code} sig=${sig}`));

let buf = '';
const pending = new Map();
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { console.log('non-json stdout:', line.slice(0, 200)); continue; }
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});

function rpc(method, params, id, timeoutMs = 120000) {
  return new Promise((resolve, reject) => {
    pending.set(id, resolve);
    const t = setTimeout(() => reject(new Error(`timeout waiting for ${method}`)), timeoutMs);
    pending.set(id, (msg) => { clearTimeout(t); resolve(msg); });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

const init = await rpc('initialize', {
  protocolVersion: '2025-06-18',
  capabilities: {},
  clientInfo: { name: 'ci-smoke', version: '0.0.0' },
}, 1);
if (init.error) throw new Error('initialize failed: ' + JSON.stringify(init.error));
console.log('MCP server:', init.result?.serverInfo?.name, init.result?.serverInfo?.version);
child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');

const tools = await rpc('tools/list', {}, 2);
if (tools.error) throw new Error('tools/list failed: ' + JSON.stringify(tools.error));
const names = tools.result.tools.map((t) => t.name);
console.log('tools exposed:', names.length);
if (!names.includes('browser_navigate')) throw new Error('browser_navigate missing: ' + names.join(','));

const nav = await rpc('tools/call', {
  name: 'browser_navigate',
  arguments: { url: 'data:text/html,<title>mcp-ok</title><h1>mcp smoke page</h1>' },
}, 3);
if (nav.error) throw new Error('navigate rpc failed: ' + JSON.stringify(nav.error));
const text = JSON.stringify(nav.result);
if (nav.result?.isError) throw new Error('navigate tool error: ' + text.slice(0, 800));
if (!text.includes('mcp-ok') && !text.includes('mcp smoke')) {
  throw new Error('snapshot missing page content: ' + text.slice(0, 800));
}
console.log('browser_navigate ok (snapshot contains page content)');

await rpc('tools/call', { name: 'browser_close', arguments: {} }, 4, 30000).catch(() => {});
child.kill('SIGTERM');
console.log('MCP stdio smoke OK');
process.exit(0);

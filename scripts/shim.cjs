// OHOS node reports process.platform === 'openharmony'; playwright-core only
// understands linux/darwin/win32 and refuses to launch otherwise. Preload with
// `node --require shim.cjs ...` before any playwright code loads.
if (process.platform !== 'linux') {
  try { Object.defineProperty(process, 'platform', { value: 'linux' }); } catch {}
  try {
    const os = require('os');
    os.platform = () => 'linux';
  } catch {}
}

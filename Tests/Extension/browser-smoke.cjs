// Node 22+；独立临时配置，不访问日常浏览器资料。App 用隔离测试端口模拟。
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const listen = (server, port) => new Promise((resolve, reject) => server.once('error', reject).listen(port, '127.0.0.1', resolve));
async function cdp(url) {
  const ws = new WebSocket(url); let next = 0; const pending = new Map();
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  ws.onmessage = event => { const m = JSON.parse(event.data); if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(Error(JSON.stringify(m.error))) : p.resolve(m.result); } };
  return { ws, call(method, params = {}) { return new Promise((resolve, reject) => { const id = ++next; pending.set(id, { resolve, reject }); ws.send(JSON.stringify({ id, method, params })); }); } };
}
(async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'qd-browser-'));
  let browser, app, pageCDP, workerCDP, browserCDP, extensionCDP;
  const adds = []; let fileRequests = 0; let startedAt = Date.now();
  const site = http.createServer((req, res) => {
    if (req.url.startsWith('/tiny')) { res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="tiny.zip"', 'Content-Length': 1 }); res.end('x'); return; }
    if (req.url.startsWith('/file')) { fileRequests++; res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="smoke.zip"', 'Content-Length': 1024 * 1024 }); const timer = setInterval(() => res.write(Buffer.alloc(1024)), 5); res.on('close', () => clearInterval(timer)); }
    else { res.writeHead(200, { 'Content-Type': 'text/html', 'Set-Cookie': 'auth=browser-test' }); res.end('<a id="download" href="/file.zip">Download</a>'); }
  });
  try {
    await listen(site, 18777);
    const ext = path.join(temp, 'extension'); await fs.cp(path.resolve(__dirname, '../../Extension'), ext, { recursive: true });
    const bg = path.join(ext, 'background.js'); await fs.writeFile(bg, (await fs.readFile(bg, 'utf8')).replace(/const PORTS = \[[^;]+;/, 'const PORTS = [19588];'));
    browser = spawn(process.env.QD_BROWSER_BINARY || '/Applications/Thorium.app/Contents/MacOS/Thorium', ['--headless=new', '--no-first-run', '--no-default-browser-check', '--no-proxy-server', '--remote-debugging-port=0', '--enable-unsafe-extension-debugging', '--user-data-dir=' + path.join(temp, 'profile'), '--load-extension=' + ext, '--disable-extensions-except=' + ext, '--host-resolver-rules=MAP download.quickdown.invalid 127.0.0.1', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
    let logs = ''; browser.stderr.on('data', data => logs += data.toString());
    let port;
    for (let i = 0; i < 100; i++) { try { port = (await fs.readFile(path.join(temp, 'profile/DevToolsActivePort'), 'utf8')).split('\n')[0]; break; } catch {} await wait(100); }
    if (!port) throw Error('Browser failed: ' + logs.slice(-1000));
    const endpoint = 'http://127.0.0.1:' + port;
    const version = await (await fetch(endpoint + '/json/version')).json(); browserCDP = await cdp(version.webSocketDebuggerUrl);
    await browserCDP.call('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: path.join(temp, 'downloads') });
    console.log('Browser: ' + version.Browser);
    const {id: extId} = await browserCDP.call('Extensions.loadUnpacked', { path: ext });
    let targets;
    for (let i = 0; i < 80; i++) { targets = await (await fetch(endpoint + '/json/list')).json(); if (targets.some(t => t.type === 'service_worker' && t.url.startsWith('chrome-extension://' + extId + '/'))) break; await wait(100); }
    const worker = targets.find(t => t.type === 'service_worker' && t.url.startsWith('chrome-extension://' + extId + '/')); assert.ok(worker, 'Extension service worker loaded: ' + JSON.stringify(targets.map(t => ({type:t.type,url:t.url}))));
    workerCDP = await cdp(worker.webSocketDebuggerUrl);
    const evaluateWorker = async expression => { const result = await workerCDP.call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }); if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails)); return result.result.value; };
    await workerCDP.call('Runtime.enable');
    await workerCDP.call('Runtime.runIfWaitingForDebugger');
    await wait(300);
    console.log('Worker:', worker.url, await evaluateWorker('chrome.runtime.getManifest().name'));
    await evaluateWorker('settingsLoaded');
    const extTarget = await browserCDP.call('Target.createTarget', { url: 'chrome-extension://' + extId + '/options.html' });
    const newTargets = await (await fetch(endpoint + '/json/list')).json();
    extensionCDP = await cdp(newTargets.find(t => t.id === extTarget.targetId).webSocketDebuggerUrl);
    await wait(200);
    const evaluateAPI = async expression => { const result = await extensionCDP.call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }); if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails)); return result.result.value; };
    pageCDP = await cdp(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
    await pageCDP.call('Page.navigate', { url: 'http://download.quickdown.invalid:18777/' });
    await wait(600);
    await pageCDP.call('Runtime.evaluate', { expression: 'document.getElementById("download").click()' });
    await wait(800);
    assert.equal(fileRequests, 1, 'Real browser download attempted offline');
    assert.equal(await evaluateAPI('chrome.downloads.search({}).then(items => items.length)'), 0, 'Captured offline download removed');
    assert.equal(await evaluateAPI('chrome.storage.session.get("qd_pending_queue").then(s => !!s.qd_pending_queue)'), false);
    console.log('PASS: actual offline browser download intercepted without queue');
    startedAt = Date.now();
    app = http.createServer((req, res) => {
      res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-QuickDown-Session, X-QuickDown-Captured-At');
      if (req.method === 'OPTIONS') { res.end(); return; }
      if (req.url === '/integration') { res.end(JSON.stringify({ name: 'QuickDown', protocol: 2, session: 'real-browser-session', startedAt })); return; }
      if (req.url === '/sniff') { res.end('on'); return; }
      if (req.url === '/add') { let body = ''; req.on('data', d => body += d); req.on('end', () => { adds.push(JSON.parse(body)); res.end('{"ok":true}'); }); return; }
      res.writeHead(404); res.end();
    });
    await listen(app, 19588);
    await evaluateAPI('chrome.runtime.sendMessage({type: "recheck"})'); await wait(800);
    assert.equal(adds.length, 0, 'App startup did not replay offline download');
    await pageCDP.call('Runtime.evaluate', { expression: 'document.getElementById("download").click()' });
    for (let i = 0; i < 40 && !adds.length; i++) await wait(100);
    assert.equal(adds.length, 1); assert.equal(adds[0].filename, 'smoke.zip'); assert.match(adds[0].cookie, /auth=browser-test/);
    assert.equal(await evaluateAPI('chrome.downloads.search({}).then(items => items.length)'), 0);
    console.log('PASS: actual online browser download handed off once with filename and cookies');
    await pageCDP.call('Runtime.evaluate', { expression: 'document.getElementById("download").href = "/tiny.zip"; document.getElementById("download").click()' });
    for (let i = 0; i < 40 && adds.length < 2; i++) await wait(100);
    await wait(300);
    assert.equal(adds.length, 2); assert.equal(adds[1].filename, 'tiny.zip');
    assert.equal(await evaluateAPI('chrome.downloads.search({}).then(items => items.length)'), 0);
    const remainingFiles = await fs.readdir(path.join(temp, 'downloads')).catch(() => []);
    assert.equal(remainingFiles.length, 0, 'No completed or partial browser file remains');
    console.log('PASS: one-byte download handed off once without residual browser file');
    console.log('Browser: ' + version.Browser);
  } finally {
    for (const connection of [pageCDP, workerCDP, browserCDP, extensionCDP]) connection?.ws.close();
    if (browser) { browser.kill('SIGTERM'); await wait(300); }
    site.closeAllConnections(); site.close(); if (app) { app.closeAllConnections(); app.close(); }
    await fs.rm(temp, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

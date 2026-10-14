// macOS + Node 22+；同一助手源码启动独立临时 App。先 swift build --product QuickDownBridge。
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn, execFileSync } = require('node:child_process');

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
  const startedFile = path.join(temp, 'started.json');
  const tasksFile = path.join(temp, 'tasks.jsonl');
  let fileRequests = 0;
  const site = http.createServer((req, res) => {
    if (req.url.startsWith('/tiny')) { res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="tiny.zip"', 'Content-Length': 1 }); res.end('x'); return; }
    if (req.url.startsWith('/file')) { fileRequests++; res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="smoke.zip"', 'Content-Length': 1024 * 1024 }); const timer = setInterval(() => res.write(Buffer.alloc(1024)), 5); res.on('close', () => clearInterval(timer)); }
    else { res.writeHead(200, { 'Content-Type': 'text/html', 'Set-Cookie': 'auth=browser-test' }); res.end('<a id="download" href="/file.zip">Download</a>'); }
  });
  try {
    await listen(site, 18777);
    const ext = path.join(temp, 'extension'); await fs.cp(path.resolve(__dirname, '../../Extension'), ext, { recursive: true });
    const bg = path.join(ext, 'background.js'); await fs.writeFile(bg, (await fs.readFile(bg, 'utf8')).replace(/const PORTS = \[[^;]+;/, 'const PORTS = [19588];'));
    const fixture = path.join(temp, 'QuickDownFixture.app');
    const macOS = path.join(fixture, 'Contents/MacOS'); await fs.mkdir(macOS, { recursive: true });
    const bridge = path.join(macOS, 'QuickDownBridge');
    // 使用同一助手源码，仅替换 fixture 的端口/BundleID，不触碰日常 App。
    const bridgeSource = path.join(temp, 'Bridge.swift');
    const production = await fs.readFile(path.resolve(__dirname, '../../Sources/QuickDownBridge/main.swift'), 'utf8');
    await fs.writeFile(bridgeSource, production.replace('10007...10016', '19588...19588').replace('com.quickdown.app', 'com.quickdown.nativefixture'));
    const objectDir = path.resolve(__dirname, '../../.build/debug/QuickDownCore.build');
    const objects = (await fs.readdir(objectDir)).filter(f => f.endsWith('.o')).map(f => path.join(objectDir, f));
    execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-I', path.resolve(__dirname, '../../.build/debug/Modules'), bridgeSource, ...objects, '-o', bridge],
      { env: { ...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' } });
    await fs.chmod(bridge, 0o755);
    await fs.writeFile(path.join(fixture, 'Contents/Info.plist'), `<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.quickdown.nativefixture</string><key>CFBundleExecutable</key><string>QuickDownFixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSUIElement</key><true/></dict></plist>`);
    const script = path.join(temp, 'fixture.cjs');
    await fs.writeFile(script, `const fs=require('node:fs'),http=require('node:http');
const startedAt=Date.now(),session='native-fixture-session';
fs.writeFileSync(${JSON.stringify(startedFile)},JSON.stringify({pid:process.pid,startedAt}));
const server=http.createServer((req,res)=>{
res.setHeader('Access-Control-Allow-Origin','*');res.setHeader('Access-Control-Allow-Headers','Content-Type, X-QuickDown-Session, X-QuickDown-Captured-At');
if(req.method==='OPTIONS'){res.end();return;}
if(req.url==='/integration'){res.end(JSON.stringify({name:'QuickDown',protocol:2,session,startedAt}));return;}
if(req.url==='/sniff'){res.end('on');return;}
if(req.url==='/add'){let body='';req.on('data',d=>body+=d);req.on('end',()=>{if(req.headers['x-quickdown-session']!==session || !Number.isFinite(Number(req.headers['x-quickdown-captured-at'])) || Number(req.headers['x-quickdown-captured-at'])<startedAt || Date.now()-Number(req.headers['x-quickdown-captured-at'])>3000){res.writeHead(409);res.end();return;}fs.appendFileSync(${JSON.stringify(tasksFile)},body+'\\n');res.end('{"ok":true}');});return;}
if(req.url==='/activate'){res.end('ok');return;}
res.writeHead(404);res.end();
});server.listen(19588,'127.0.0.1');`);
    await fs.writeFile(path.join(macOS, 'QuickDownFixture'), '#!/bin/sh\nexec ' + JSON.stringify(process.execPath) + ' ' + JSON.stringify(script) + '\n');
    await fs.chmod(path.join(macOS, 'QuickDownFixture'), 0o755);
    const profile = path.join(temp, 'profile'); await fs.mkdir(profile);
    execFileSync(bridge, ['--register-home', temp, '--extension-path', ext, '--browser-data-dir', profile]);
    const tasks = async () => { try { return (await fs.readFile(tasksFile,'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse); } catch { return []; } };
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
    // 此时模拟 App 未运行；点击应经过真实 Native Messaging -> 编译的助手 -> /usr/bin/open。
    await pageCDP.call('Runtime.evaluate', { expression: 'document.getElementById("download").click()' });
    for (let i = 0; i < 100 && !(await tasks()).length; i++) await wait(100);
    const initial = await tasks();
    if (initial.length !== 1) {
      console.log('Native diagnostic:', await evaluateAPI('new Promise(resolve => chrome.runtime.sendNativeMessage("com.quickdown.bridge", {action:"launch"}, reply => resolve({reply, error:chrome.runtime.lastError?.message})))'));
      console.log('Registered origins:', JSON.parse(await fs.readFile(path.join(temp, 'profile/NativeMessagingHosts/com.quickdown.bridge.json'),'utf8')).allowed_origins, 'actual:', extId);
      console.log('Paths:', {ext, real:await fs.realpath(ext)}, 'manifest:', await evaluateAPI('chrome.runtime.getManifest()'));
      console.log('App started:', await fs.readFile(startedFile,'utf8').catch(() => 'no'));
    }
    assert.equal(initial.length, 1, '离线点击自动启动并交接');
    const started = JSON.parse(await fs.readFile(startedFile, 'utf8')); assert.ok(started.pid);
    assert.equal(initial[0].filename, 'smoke.zip'); assert.match(initial[0].cookie, /auth=browser-test/);
    assert.equal(await evaluateAPI('chrome.downloads.search({}).then(items => items.length)'), 0);
    assert.equal(await evaluateAPI('chrome.storage.session.get("qd_pending_queue").then(s => !!s.qd_pending_queue)'), false);
    console.log('PASS: real Native Messaging helper opens App fixture and delivers the triggering download once');
    for (let click = 0; click < 2; click++) {
      await pageCDP.call('Runtime.evaluate', { expression: 'document.getElementById("download").click()' });
      for (let i = 0; i < 40 && (await tasks()).length < click + 2; i++) await wait(100);
    }
    assert.equal((await tasks()).length, 3);
    assert.equal(JSON.parse(await fs.readFile(startedFile, 'utf8')).pid, started.pid);
    console.log('PASS: subsequent downloads use the same running App');
    console.log('Browser: ' + version.Browser);
  } finally {
    for (const connection of [pageCDP, workerCDP, browserCDP, extensionCDP]) connection?.ws.close();
    if (browser) { browser.kill('SIGTERM'); await wait(300); }
    try { const {pid} = JSON.parse(await fs.readFile(startedFile,'utf8')); process.kill(pid,'SIGTERM'); await wait(100); } catch {}
    site.closeAllConnections(); site.close(); if (app) { app.closeAllConnections(); app.close(); }
    await fs.rm(temp, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

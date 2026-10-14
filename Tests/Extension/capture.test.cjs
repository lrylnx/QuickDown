const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../Extension/background.js'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

async function extension(options = {}) {
  const listeners = {};
  const calls = { cancel: [], pause: [], resume: [], adds: [], notices: [], erase: [] };
  const session = { qd_pending_queue: [{ url: 'https://old.example/file.zip' }] };
  const local = { ...session };
  let online = options.online !== false;
  let appSession = 'session-1';
  let startedAt = Date.now() - 10000;
  let releaseSettings;
  function event(name) { return { addListener(fn) { (listeners[name] ||= []).push(fn); } }; }
  function store(data) {
    return {
      async get(defaults) { return { ...(typeof defaults === "object" ? defaults : {}), ...data }; }, async set(values) { Object.assign(data, values); },
      async remove(keys) { for (const key of [].concat(keys)) delete data[key]; },
    };
  }
  const chrome = {
    storage: {
      sync: { get(defaults, callback) {
        if (!callback) return Promise.resolve({ ...defaults, ...options.settings });
        releaseSettings = () => callback({ ...defaults, ...options.settings });
        if (!options.cold) setImmediate(releaseSettings);
      }, async set() {} },
      session: store(session), local: store(local), onChanged: event('storage'),
    },
    runtime: { onInstalled: event('installed'), onStartup: event('startup'), onMessage: event('message') },
    downloads: {
      onCreated: event('created'), onChanged: event('changed'),
      async pause(id) { calls.pause.push(id); }, async resume(id) { calls.resume.push(id); },
      cancel(id, callback) { calls.cancel.push(id); callback(); },
      async removeFile() {}, async erase(item) { calls.erase.push(item.id); },
    },
    notifications: { async create(item) { calls.notices.push(item); } },
    cookies: { getAll(query, callback) { callback([{ name: 'auth', value: 'token' }]); } },
    contextMenus: { onClicked: event('menu'), removeAll(cb) { cb(); }, create() {}, remove(id, cb) { cb(); } },
    webRequest: { onBeforeRequest: event('request'), onHeadersReceived: event('headers') },
    tabs: { onRemoved: event('tabRemoved'), async sendMessage() {} },
    alarms: { create() {}, onAlarm: event('alarm') },
  };
  const context = vm.createContext({ chrome, navigator: { userAgent: 'Browser-UA' }, URL, AbortController,
    setTimeout, clearTimeout, console,
    async fetch(url, init) {
      if (!online || !url.startsWith('http://127.0.0.1:10007/')) throw Error('offline');
      if (url.endsWith('/integration')) return { ok: true, async text() {
        return JSON.stringify({ name: options.impostor ? 'OtherApp' : 'QuickDown', protocol: 2, session: appSession, startedAt });
      } };
      if (url.endsWith('/sniff')) return { ok: true, async text() { return 'on'; } };
      if (url.endsWith('/add')) {
        calls.adds.push({ ...JSON.parse(init.body), headers: init.headers });
        return { ok: !options.rejectAdd, async text() { return '{}'; } };
      }
      throw Error('unexpected endpoint');
    },
  });
  vm.runInContext(source, context);
  if (!options.cold) { await tick(); await tick(); }
  return {
    calls, session, local, releaseSettings: () => releaseSettings(),
    online(value) { online = value; }, restart() { appSession = 'session-2'; startedAt = Date.now() + 1; },
    async capture(id = 1, extra = {}) {
      await vm.runInContext(`takeOver(${JSON.stringify({ id, url: 'https://example.com/file.zip', filename: 'file.zip', referrer: 'https://example.com/page', ...extra })}, { eraseFromHistory: true })`, context);
    },
    emit(name, value) { for (const fn of listeners[name] || []) fn(value); },
    async message(msg) { return new Promise(resolve => listeners.message[0](msg, { tab: { id: 2, url: 'https://example.com/page' } }, resolve)); },
  };
}

test('offline capture cancels, clears both legacy queues, and never replays after startup/alarm/recheck', async () => {
  const e = await extension({ online: false });
  await e.capture();
  assert.deepEqual(e.calls.cancel, [1]);
  assert.equal(e.session.qd_pending_queue, undefined);
  assert.equal(e.local.qd_pending_queue, undefined);
  e.online(true);
  e.emit('startup'); e.emit('alarm', { name: 'qd-keepalive' });
  await e.message({ type: 'recheck' }); await tick();
  assert.equal(e.calls.adds.length, 0);
  await e.capture(2); assert.equal(e.calls.adds.length, 1);
});
test('online capture preserves filename, final URL, referer, cookies, UA and session', async () => {
  const e = await extension(); await e.capture(1, { finalUrl: 'https://cdn.example.com/file.zip' });
  const item = e.calls.adds[0];
  assert.equal(item.url, 'https://cdn.example.com/file.zip');
  assert.equal(item.filename, 'file.zip'); assert.equal(item.referer, 'https://example.com/page');
  assert.equal(item.cookie, 'auth=token'); assert.equal(item.userAgent, 'Browser-UA');
  assert.equal(item.headers['X-QuickDown-Session'], 'session-1');
});
test('duplicate download events send once; distinct downloads of the same URL remain independent', async () => {
  const e = await extension(); await Promise.all([e.capture(1), e.capture(1), e.capture(2)]);
  assert.equal(e.calls.adds.length, 2); assert.deepEqual(e.calls.cancel, [1, 2]);
});
for (const [name, settings, extra] of [
  ['disabled', { mode: 'off' }, {}], ['excluded', { excluded: 'example.com' }, {}],
  ['media filter', { filter: 'media' }, { filename: 'file.pdf', url: 'https://example.com/file.pdf', mime: 'application/pdf' }],
]) test(`cold worker honors ${name} settings and resumes native download`, async () => {
  const e = await extension({ cold: true, settings }); const task = e.capture(1, extra);
  await tick(); assert.deepEqual(e.calls.pause, [1]); e.releaseSettings(); await task;
  assert.deepEqual(e.calls.resume, [1]); assert.equal(e.calls.cancel.length, 0); assert.equal(e.calls.adds.length, 0);
});
test('cold worker with capture enabled pauses then cancels and sends', async () => {
  const e = await extension({ cold: true }); const task = e.capture(); await tick(); e.releaseSettings(); await task;
  assert.deepEqual(e.calls.cancel, [1]); assert.equal(e.calls.adds.length, 1);
});
test('rejects an App that started after the download event', async () => {
  const e = await extension(); e.restart(); await e.capture(); assert.equal(e.calls.adds.length, 0);
});
test('rejects another application on QuickDown ports', async () => {
  const e = await extension({ impostor: true }); await e.capture(); assert.equal(e.calls.adds.length, 0);
});
test('failed add is discarded without retry', async () => {
  const e = await extension({ rejectAdd: true }); await e.capture(); await e.message({ type: 'recheck' });
  assert.equal(e.calls.adds.length, 1); assert.equal(e.session.qd_pending_queue, undefined);
});
test('offline video and context menu requests never queue', async () => {
  const e = await extension({ online: false });
  assert.equal((await e.message({ type: 'downloadVideo', url: 'https://example.com/video.mp4' })).ok, false);
  e.emit('menu', { menuItemId: 'qd-link', linkUrl: 'https://example.com/file.zip' }); await tick();
  e.online(true); await e.message({ type: 'recheck' }); assert.equal(e.calls.adds.length, 0);
});
test('online video and context menu retain handoff functionality', async () => {
  const e = await extension();
  assert.equal((await e.message({ type: 'downloadVideo', url: 'https://example.com/video.mp4' })).ok, true);
  e.emit('menu', { menuItemId: 'qd-image', srcUrl: 'https://example.com/image.jpg' }); await tick(); await tick();
  assert.equal(e.calls.adds.length, 2);
});

test('Content-Disposition supplies early filename even with sniff disabled and media filter enabled', async () => {
  const e = await extension({ settings: { sniff: false, filter: 'media' } });
  e.emit('headers', { tabId: 1, url: 'https://example.com/download.php', responseHeaders: [
    { name: 'Content-Disposition', value: 'attachment; filename="installer.zip"' },
  ] });
  await e.capture(1, { url: 'https://example.com/download.php', filename: '', mime: 'application/octet-stream' });
  assert.equal(e.calls.adds[0].filename, 'installer.zip');
});
test('RFC 5987 UTF-8 filename takes precedence over plain filename', async () => {
  const e = await extension();
  e.emit('headers', { tabId: 1, url: 'https://example.com/download', responseHeaders: [
    { name: 'content-disposition', value: "attachment; filename=download.zip; filename*=UTF-8''%E6%B5%8B%E8%AF%95.zip" },
  ] });
  await e.capture(1, { url: 'https://example.com/download', filename: '' });
  assert.equal(e.calls.adds[0].filename, '测试.zip');
});

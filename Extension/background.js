// 速下 - 浏览器下载接管 后台服务
//
// 接管灵敏度核心设计（参考 Ghost-Downloader-3）：
// 0. SW 常驻保活：MV3 SW 空闲约 30 秒会被休眠，休眠期间下载到来需要先唤醒 SW，
//    唤醒耗时内浏览器原生下载已在进行，快速网络下 cancel 执行前文件可能已完成。
//    每 20 秒调用一次轻量扩展 API 重置空闲计时器，让 SW 永不休眠，
//    onCreated → cancel 稳定在毫秒级执行 —— 这是 100% 接管的关键。
// 1. 设置在 SW 启动时预加载到内存，事件 hot path 零异步读取
// 2. onCreated 单点完整接管，不使用 onDeterminingFilename —— 该事件的 suggest
//    协议极易产生 "Download must be in progress" / "suggestCallback may not be
//    called more than once" 控制台报错（详见下载事件监听一节），对接管可靠性
//    没有实质增益，cancel 之前零 await
// 3. 并行端口发现 + 活跃端口持久化
// 4. 任务队列：速下未启动时暂存，启动后自动补发
// 5. alarms 定期保活 + 队列 flush
// 6. onChanged 兜底：极小文件在 cancel 落地前已被浏览器下载完成时，
//    删除磁盘文件并抹掉下载历史（任务早已发给速下），不留浏览器下载痕迹
// 7. SW 启动时清扫接管浏览器中已在进行中的下载（扩展刚装载 / 浏览器恢复场景）

const PORTS = [10007, 10008, 10009, 10010, 10011, 10012, 10013, 10014, 10015, 10016];
const DEFAULTS = { mode: "auto", filter: "all", excluded: "", sniff: true, sniffApp: true };
const ACTIVE_PORT_KEY = "qd_active_port";
const QUEUE_KEY = "qd_pending_queue";
const MAX_QUEUE = 50;

// ============================================================================
// 设置：内存预加载（hot path 绝不读 storage）
// ============================================================================

let settings = { ...DEFAULTS };
let settingsReady = false;

// SW 启动时立即发起异步加载，加载完成前用默认值
chrome.storage.sync.get(DEFAULTS, (s) => {
  settings = { ...DEFAULTS, ...s };
  settingsReady = true;
});

// 监听设置变化，实时更新内存
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "sync") return;
  let sniffChanged = false;
  for (const [key, change] of Object.entries(changes)) {
    if (key in DEFAULTS) {
      settings[key] = change.newValue;
      if (key === "sniff" || key === "sniffApp") sniffChanged = true;
    }
  }
  if (sniffChanged) applySniffMenu();
});

// ============================================================================
// 视频嗅探开关（双层）
//   App 总开关：速下 设置 → 浏览器扩展 →「网页视频嗅探」，经 /sniff 接口同步
//   扩展开关：扩展弹窗 / 扩展选项页（本浏览器独立控制）
//   两者任一关闭 → 嗅探关闭
// ============================================================================

function sniffActive() {
  return settings.sniff !== false && settings.sniffApp !== false;
}

// 从速下 App 同步总开关到 chrome.storage（SW 启动 + 每 30 秒 alarm 各同步一次）
async function syncSniffFromApp() {
  const port = await ensurePort();
  if (!port) return;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 1500);
    const r = await fetch(`http://127.0.0.1:${port}/sniff`, { signal: ctrl.signal });
    clearTimeout(t);
    if (!r.ok) return;
    const on = (await r.text()).trim() !== "off";
    const cur = await chrome.storage.sync.get({ sniffApp: true });
    if (cur.sniffApp !== on) await chrome.storage.sync.set({ sniffApp: on });
  } catch {}
}

// ============================================================================
// Service Worker 常驻保活（100% 接管的关键）
//
// Chrome 官方行为：任何扩展 API 调用都会重置 SW 的 30 秒空闲计时器。
// 每 20 秒调用一次轻量 API，SW 即永不休眠 —— 下载事件到达时无需唤醒，
// onCreated → cancel 在毫秒级完成，浏览器原生下载来不及开始。
// 极端情况下 SW 仍被杀掉（如扩展更新），alarms 会在 30 秒内重新唤醒并重建本循环。
// ============================================================================

function keepAliveTick() {
  try {
    chrome.runtime.getPlatformInfo(() => void chrome.runtime.lastError);
  } catch (e) {}
}

keepAliveTick();
setInterval(keepAliveTick, 20 * 1000);

// ============================================================================
// 存储辅助
// ============================================================================

const sessionStore = chrome.storage.session || chrome.storage.local;

async function loadActivePortCache() {
  try {
    const r = await sessionStore.get(ACTIVE_PORT_KEY);
    const p = r[ACTIVE_PORT_KEY];
    if (typeof p === "number" && PORTS.includes(p)) return p;
  } catch {}
  return null;
}

async function saveActivePortCache(port) {
  try { await sessionStore.set({ [ACTIVE_PORT_KEY]: port }); } catch {}
}

async function clearActivePortCache() {
  try { await sessionStore.remove(ACTIVE_PORT_KEY); } catch {}
}

// ============================================================================
// 端口发现（并行竞速 + 缓存优先）
// ============================================================================

let activePort = null;
let lastPingTime = 0;

async function ping(port) {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 350);
    const r = await fetch(`http://127.0.0.1:${port}/ping`, { signal: ctrl.signal });
    clearTimeout(t);
    return r.ok && (await r.text()) === "ok";
  } catch {
    return false;
  }
}

// 并行竞速：谁先应谁赢，最多等 400ms
function findPortParallel() {
  return new Promise((resolve) => {
    let settled = false;
    const timers = [];
    const done = (port) => {
      if (settled) return;
      settled = true;
      timers.forEach(clearTimeout);
      resolve(port);
    };
    PORTS.forEach((p) => {
      ping(p).then((ok) => { if (ok) done(p); });
    });
    timers.push(setTimeout(() => done(null), 400));
  });
}

async function findPort() {
  const cached = await loadActivePortCache();
  if (cached && await ping(cached)) {
    activePort = cached;
    return cached;
  }
  const p = await findPortParallel();
  if (p) {
    activePort = p;
    await saveActivePortCache(p);
  } else {
    activePort = null;
    await clearActivePortCache();
  }
  return p;
}

async function ensurePort() {
  const now = Date.now();
  if (activePort && now - lastPingTime < 5000) {
    if (await ping(activePort)) return activePort;
  }
  lastPingTime = now;
  return findPort();
}

// ============================================================================
// 任务队列
// ============================================================================

async function getQueue() {
  try {
    const r = await sessionStore.get(QUEUE_KEY);
    return Array.isArray(r[QUEUE_KEY]) ? r[QUEUE_KEY] : [];
  } catch { return []; }
}

async function setQueue(q) {
  try { await sessionStore.set({ [QUEUE_KEY]: q.slice(0, MAX_QUEUE) }); } catch {}
}

async function enqueueTask(item) {
  const q = await getQueue();
  if (q.some((t) => t.url === item.url)) return;
  q.push({ ...item, queuedAt: Date.now() });
  await setQueue(q);
}

async function flushQueue() {
  const q = await getQueue();
  if (!q.length) return 0;
  const port = await ensurePort();
  if (!port) return 0;
  let sent = 0;
  const remaining = [];
  for (const item of q) {
    const ok = await sendToApp(item, port);
    if (ok) sent++;
    else remaining.push(item);
  }
  await setQueue(remaining);
  return sent;
}

// ============================================================================
// 文件名推导
// ============================================================================

// 哈希名：MD5 32 位 / SHA1 40 位十六进制（蓝奏云等网盘 CDN 的路径名）
function isHashName(name) {
  const base = name.replace(/\.[^.]+$/, "");
  return /^[0-9a-fA-F]{32}$/.test(base) || /^[0-9a-fA-F]{40}$/.test(base);
}

// 推导更可靠的文件名：
// 浏览器在拿不到 Content-Disposition 时只会用 URL 路径末段兜底（如蓝奏云的
// 025fcd6c….pkg），真实文件名往往藏在查询参数里（fileName=…）。
// 规则：给定名是「空 / 哈希名 / 通用名 / URL 路径末段」之一，且 URL 查询参数
// 带真实名时，用查询参数名覆盖；否则保留浏览器名（它可能来自 Content-Disposition）。
function deriveFilename(item) {
  const urlStr = item.finalUrl || item.url || "";
  let queryName;
  let pathBase = "";
  try {
    const u = new URL(urlStr);
    for (const key of u.searchParams.keys()) {
      if (key.toLowerCase() === "filename" || key.toLowerCase() === "file_name") {
        const v = (u.searchParams.get(key) || "").trim();
        if (v) { queryName = v; break; }
      }
    }
    pathBase = decodeURIComponent(u.pathname.split("/").pop() || "");
  } catch (e) {}

  let provided = (item.filename || "").replace(/^.*[\\/]/, "").trim();
  if (queryName && (!provided || provided === pathBase || isHashName(provided))) {
    return queryName;
  }
  return provided || pathBase || "";
}

// ============================================================================
// 视频大小探测（嗅探按钮显示 MB/GB 用）
// ============================================================================

const sizeCache = new Map(); // url -> { size, at }（失败也缓存，避免反复探测）

async function probeVideoSize(url) {
  const cached = sizeCache.get(url);
  if (cached && Date.now() - cached.at < 10 * 60 * 1000) return cached.size;
  let size = null;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 6000);
    const resp = await fetch(url, {
      method: "GET",
      headers: { Range: "bytes=0-0" },
      signal: ctrl.signal,
    });
    clearTimeout(t);
    if (resp.status === 206) {
      const cr = resp.headers.get("content-range"); // bytes 0-0/总大小
      const m = cr && cr.match(/\/(\d+)\s*$/);
      if (m) size = parseInt(m[1], 10);
    } else if (resp.ok) {
      const cl = resp.headers.get("content-length");
      if (cl) size = parseInt(cl, 10);
    }
    try { await resp.body?.cancel(); } catch (e) {}
  } catch (e) {}
  sizeCache.set(url, { size, at: Date.now() });
  return size;
}

// ============================================================================
// 请求身份补全（User-Agent + Cookie）
//
// 右键菜单 / 接管路径把 URL 交给速下后，由速下用自己的会话重新下载。
// 它没有浏览器的请求上下文：UA 只能回退到 QuickDown/1.0，Cookie 完全缺失。
// 防盗链 CDN（图片站、电商详情图等）对非常规 UA / 无 Cookie 的请求会返回
// 占位图或错误内容 —— 表现为「下载到的不是原图」。
// 这里统一在发送前补上浏览器 UA 和该 URL 域下的 Cookie。
// ============================================================================

function buildCookieHeader(url) {
  return new Promise((resolve) => {
    try {
      chrome.cookies.getAll({ url }, (cookies) => {
        void chrome.runtime.lastError;
        if (!Array.isArray(cookies) || cookies.length === 0) return resolve(undefined);
        const header = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
        resolve(header.length > 16384 ? header.slice(0, 16384) : header);
      });
    } catch (e) {
      resolve(undefined);
    }
  });
}

async function enrichPayload(payload) {
  if (!payload.userAgent) payload.userAgent = navigator.userAgent;
  if (!payload.cookie && payload.url && /^https?:/i.test(payload.url)) {
    payload.cookie = await buildCookieHeader(payload.url);
  }
  return payload;
}

// ============================================================================
// 交给速下
// ============================================================================

async function sendToApp(item, portOverride) {
  const port = portOverride || (await ensurePort());
  if (!port) return false;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 1500);
    const resp = await fetch(`http://127.0.0.1:${port}/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: item.url,
        filename: item.filename || undefined,
        referer: item.referer || undefined,
        userAgent: item.userAgent || undefined,
        cookie: item.cookie || undefined,
      }),
      signal: ctrl.signal,
    });
    clearTimeout(t);
    return resp.ok;
  } catch {
    return false;
  }
}

// ============================================================================
// 过滤（纯同步，读内存 settings）
// ============================================================================

// 「仅媒体与安装包」的扩展名白名单 —— 与选项页文案一致：视频/音频/压缩包/安装包。
// 注意不要把 pdf/doc/txt/json 等文档与代码后缀加进来：白名单过宽时该选项
// 对常见下载几乎不过滤，表现为「所有文件与仅媒体没区别」。
const MEDIA_RE = /\.(mp4|mkv|avi|mov|flv|webm|ts|m4v|mpg|mpeg|wmv|3gp|mp3|wav|flac|aac|ogg|m4a|wma|opus|ape|zip|rar|7z|tar|gz|bz2|xz|zst|dmg|pkg|iso|apk|exe|msi|deb|rpm|appimage)(\?|#|$)/i;
const MEDIA_MIME = /^(video\/|audio\/)/;

function isExcluded(url, excludedText) {
  try {
    const host = new URL(url).hostname;
    return excludedText
      .split(/[\n,，;；]/)
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean)
      .some((e) => host === e || host.endsWith("." + e));
  } catch {
    return false;
  }
}

function shouldCapture(item) {
  const url = item.finalUrl || item.url;
  if (!url || (!url.startsWith("http://") && !url.startsWith("https://"))) return false;
  if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) return false;
  if (isExcluded(url, settings.excluded)) return false;
  if (settings.filter === "media") {
    const mimeOk = item.mime && MEDIA_MIME.test(item.mime);
    const extOk = MEDIA_RE.test(item.filename || url);
    if (!mimeOk && !extOk) return false;
  }
  return true;
}

// ============================================================================
// 通知
// ============================================================================

function notify(title, message) {
  try {
    // MV3 下 create 返回 Promise，拒绝（如图标缺失）无人接会成为
    // Unhandled rejection 噪音，显式吞掉
    const r = chrome.notifications.create({
      type: "basic",
      iconUrl: "icons/icon128.png",
      title,
      message,
    });
    if (r && typeof r.catch === "function") r.catch(() => {});
  } catch (e) {}
}

// ============================================================================
// 去重 + 兜底清理（同步）
// ============================================================================

// 已接管的 download id：同一 item 的重复事件只发一次任务
// （按 id 而不是按 url 去重 —— 按 url 去重会误杀 8 秒内的重复下载，
//  把第二次下载白白放给浏览器）
//
// 注意：只增不删。相关事件（onChanged 等）的派发可能明显迟到（SW 唤醒慢、
// 队列拥堵），若 cancel/erase 一完成就把 id 删掉，迟到的事件会把已接管的下载
// 误判成未接管。id 单调递增永不复用，靠 500 上限裁剪即可。
const capturedIds = new Set();
function markCaptured(id) {
  if (capturedIds.has(id)) return false;
  capturedIds.add(id);
  if (capturedIds.size > 500) {
    // 下载 id 单调递增，保留后一半即可
    const arr = [...capturedIds];
    capturedIds.clear();
    for (const v of arr.slice(arr.length / 2)) capturedIds.add(v);
  }
  return true;
}

// onChanged 兜底：cancel 与下载完成竞速失败时（极小文件在毫秒级完成），
// 浏览器已完成下载。任务早已交给速下，这里删除磁盘文件并抹掉下载历史，
// 不留浏览器下载痕迹。
chrome.downloads.onChanged.addListener((delta) => {
  if (!capturedIds.has(delta.id)) return;
  const state = delta.state && delta.state.current;
  if (state === "complete") {
    (async () => {
      try { await chrome.downloads.removeFile(delta.id); } catch (e) {}
      try { await chrome.downloads.erase({ id: delta.id }); } catch (e) {}
    })();
  }
});

// ============================================================================
// 核心接管 —— cancel 之前零 await
// ============================================================================

async function takeOver(downloadItem, opts = {}) {
  // ---- 以下全部同步，第一个 await 是 chrome.downloads.cancel ----
  if (settings.mode === "off") return;
  if (!shouldCapture(downloadItem)) return;

  const url = downloadItem.finalUrl || downloadItem.url;
  if (!markCaptured(downloadItem.id)) return;

  const payload = {
    url,
    filename: deriveFilename(downloadItem),
    referer: downloadItem.referrer,
    // 注意：DownloadItem 没有 userAgent 字段（此前写的 downloadItem.userAgent
    // 恒为 undefined），统一由 enrichPayload 用浏览器真实 UA 补全
  };

  // ---- 第一个异步操作：立即取消浏览器下载 ----
  let cancelOk = false;
  try {
    await new Promise((resolve) => {
      chrome.downloads.cancel(downloadItem.id, () => {
        cancelOk = !chrome.runtime.lastError;
        resolve();
      });
    });
  } catch (e) {}

  if (opts.eraseFromHistory) {
    // 先删磁盘文件再抹历史：若 cancel 输给了极小文件（浏览器已完成），
    // removeFile 在这里直接清掉文件 —— 不能依赖 onChanged 里的 removeFile，
    // 因为下面的 erase 抹掉条目后，该下载的后续事件可能不再派发，文件会残留在磁盘
    try { await chrome.downloads.removeFile(downloadItem.id); } catch (e) {}
    try { await chrome.downloads.erase({ id: downloadItem.id }); } catch (e) {}
  }

  // 如果 cancel 失败（下载可能已完成），仍交给速下（与 Ghost 行为一致）
  await enrichPayload(payload);
  const ok = await sendToApp(payload);
  if (!ok) {
    await enqueueTask(payload);
  }
}

// ============================================================================
// 下载事件监听
//
// 策略：
// - SW 常驻保活（见文件头），onCreated 到达即毫秒级处理，浏览器下载来不及开始
// - onCreated：100% 触发，负责完整接管逻辑（检查、去重、cancel、发任务）
// - onChanged：极小文件在 cancel 落地前已完成时，删除文件 + 抹掉历史（见上方兜底）
// - SW 启动清扫：接管浏览器中已在进行中的下载（扩展装载/更新瞬间的漏网之鱼）
//
// 为什么不用 onDeterminingFilename（1.5.0~1.5.2 的教训）：
// 该事件的 suggest 回调有一套极严格的隐式协议，违反任何一条都会在控制台报错：
//   ① suggestCallback 必须恰好调用一次 —— 监听器若不同步返回 true，Chrome 会
//      在监听器返回后立即自动代调一次收尾；之后任何再调用都报
//      "suggestCallback may not be called more than once"
//   ② 只能对 in_progress 的下载调用 —— 对已被 cancel 的下载调用报
//      "Download must be in progress"。而接管流程必然 cancel 下载：cancel 请求
//      先发出就必先到达（IPC 有序），事后 downloads.search 拦不住（canceled
//      条目仍在结果里，erase 后的事件派发时序也不定）
//   ③ 其他扩展若也在监听该事件，先完成目标确定的会让我们的 suggest 落在
//      已完成的下载上（同 ②）
// 收益却很小：它只是比 onCreated 更早几百毫秒的拦截点，MV3 上还经常不触发。
// onCreated + SW 常驻保活已保证毫秒级 cancel，扫尾有 sweepInProgress + alarm。
// 除非要改下载文件名，否则不要碰这个事件。
// ============================================================================

// ---- onCreated：完整接管（一定触发）----
chrome.downloads.onCreated.addListener((item) => {
  void takeOver(item, { eraseFromHistory: true });
});

// ---- SW 启动清扫：接管浏览器中已在进行中的下载 ----
// 覆盖扩展刚装载、SW 被强制重启、浏览器恢复下载等事件可能遗漏的场景。
async function sweepInProgress() {
  if (settings.mode === "off") return;
  try {
    const items = await chrome.downloads.search({ state: "in_progress" });
    for (const item of items) {
      void takeOver(item, { eraseFromHistory: true });
    }
  } catch (e) {}
}
sweepInProgress();

// ============================================================================
// 视频嗅探
// ============================================================================

const VIDEO_URL_RE = /\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)(\?|&|#|$)/i;
const tabVideos = new Map();

// 记录一个媒体地址（URL 规则 + Content-Type 规则共用）
function recordVideo(tabId, url, type) {
  let list = tabVideos.get(tabId);
  if (!list) {
    list = [];
    tabVideos.set(tabId, list);
  }
  if (list.some((v) => v.url === url)) return;
  list.push({ url, type });
  if (list.length > 200) list.shift();
  persistTabVideos();
}

// MV3 的 Service Worker 会被系统回收，内存里的 tabVideos 随之丢失
// （表现为：视频页看一会儿后再点下载 → 「未找到视频地址」）。
// 防抖写入 storage.session，SW 冷启动时恢复。
let persistTimer = null;
function persistTabVideos() {
  clearTimeout(persistTimer);
  persistTimer = setTimeout(() => {
    const obj = {};
    for (const [tid, l] of tabVideos) obj[tid] = l;
    try { chrome.storage.session.set({ tabVideos: obj }); } catch (e) {}
  }, 400);
}

// SW 冷启动：恢复上次收集的媒体地址
try {
  chrome.storage.session.get({ tabVideos: {} }).then((d) => {
    for (const [tid, l] of Object.entries(d.tabVideos)) {
      if (Array.isArray(l) && l.length) tabVideos.set(Number(tid), l);
    }
  });
} catch (e) {}

chrome.webRequest.onBeforeRequest.addListener((details) => {
  if (!sniffActive()) return; // 视频嗅探已关闭：不收集任何媒体地址
  if (details.tabId < 0) return;
  const url = details.url;
  if (!VIDEO_URL_RE.test(url)) return;
  if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) return;
  const m = url.toLowerCase().match(/\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)/);
  recordVideo(details.tabId, url, m ? m[1] : "media");
}, { urls: ["<all_urls>"] });

// Content-Type 兜底：地址不带后缀的 m3u8/mp4 请求靠响应头识别
chrome.webRequest.onHeadersReceived.addListener((details) => {
  if (!sniffActive()) return;
  if (details.tabId < 0) return;
  const url = details.url;
  if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) return;
  if (VIDEO_URL_RE.test(url)) return; // 已由 URL 规则收集
  const ct = (details.responseHeaders || []).find(
    (h) => h.name.toLowerCase() === "content-type"
  );
  if (!ct || !/(mpegurl|video\/|audio\/)/i.test(ct.value || "")) return;
  recordVideo(details.tabId, url, ct.value.toLowerCase().includes("mpegurl") ? "m3u8" : "media");
}, { urls: ["<all_urls>"] }, ["responseHeaders"]);

chrome.tabs.onRemoved.addListener((tabId) => {
  tabVideos.delete(tabId);
  persistTabVideos();
});

// ============================================================================
// 右键菜单
// ============================================================================

function createMenus() {
  chrome.contextMenus.removeAll(() => {
    void chrome.runtime.lastError; // 读一下，避免 Unchecked lastError 噪音
    chrome.contextMenus.create({ id: "qd-link", title: "用速下下载此链接", contexts: ["link"] });
    chrome.contextMenus.create({ id: "qd-media", title: "用速下下载此媒体", contexts: ["video", "audio"] });
    chrome.contextMenus.create({ id: "qd-image", title: "用速下下载此图片", contexts: ["image"] });
    chrome.contextMenus.create({ id: "qd-page", title: "用速下下载当前页面", contexts: ["page"] });
    if (sniffActive()) {
      chrome.contextMenus.create({ id: "qd-sniff", title: "🎬 嗅探本页视频", contexts: ["page"] });
    }
  });
}

// 视频嗅探开关变化时同步右键菜单（关闭 → 移除嗅探菜单；开启 → 重新创建）
function applySniffMenu() {
  if (sniffActive()) {
    chrome.contextMenus.create({ id: "qd-sniff", title: "🎬 嗅探本页视频", contexts: ["page"] });
  } else {
    chrome.contextMenus.remove("qd-sniff", () => void chrome.runtime.lastError);
  }
}

chrome.runtime.onInstalled.addListener(() => {
  createMenus();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "qd-sniff") {
    if (!sniffActive()) return; // 视频嗅探已关闭
    if (tab && tab.id != null) {
      chrome.tabs.sendMessage(tab.id, { type: "showPanel" }).catch(() => {
        notify("未检测到视频", "本页暂无可用视频资源。");
      });
    }
    return;
  }
  let url = info.linkUrl || info.srcUrl || null;
  if (!url && info.pageUrl && (info.pageUrl.startsWith("http://") || info.pageUrl.startsWith("https://"))) {
    url = info.pageUrl;
  }
  if (!url) return;
  const payload = {
    url,
    filename: undefined,
    referer: tab ? tab.url : undefined,
  };
  await enrichPayload(payload);
  const ok = await sendToApp(payload);
  if (ok) {
    notify("已交给速下", "下载已添加到速下。");
  } else {
    await enqueueTask(payload);
    notify("速下未运行", "已加入等待队列，速下启动后自动下载。");
  }
});

// ============================================================================
// alarms 兜底唤醒 + 队列 flush
//
// 常驻保活失效（扩展更新导致 SW 被杀等极端情况）时，由 alarm 在 30 秒内
// 重新唤醒 SW；顶部 setInterval 保活循环随 SW 启动自动重建。
// ============================================================================

function ensureKeepaliveAlarm() {
  // Chrome 120+ 支持最小 0.5 分钟；旧版本会自动钳制到 1 分钟（仅告警，无害）
  chrome.alarms.create("qd-keepalive", { periodInMinutes: 0.5 });
}

chrome.runtime.onInstalled.addListener(() => {
  ensureKeepaliveAlarm();
});

chrome.runtime.onStartup.addListener(() => {
  ensureKeepaliveAlarm();
  sweepInProgress();
});

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== "qd-keepalive") return;
  keepAliveTick();
  syncSniffFromApp(); // 同步 App 端视频嗅探总开关
  // 补扫进行中的下载：SW 曾被杀再唤醒的窗口期内 onCreated 可能已迟到/丢失，
  // 这里把仍在浏览器里的下载补接管（markCaptured 按 id 去重，已接管的直接跳过）
  sweepInProgress();
  const port = await ensurePort();
  if (port) {
    const sent = await flushQueue();
    if (sent > 0) {
      notify("速下已连接", `已补发 ${sent} 个等待中的下载。`);
    }
  }
});

// ============================================================================
// 消息处理
// ============================================================================

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "getStatus") {
    ensurePort().then((port) => sendResponse({ connected: !!port, port }));
    return true;
  }
  if (msg && msg.type === "recheck") {
    activePort = null;
    ensurePort().then(async (port) => {
      if (port) {
        const sent = await flushQueue();
        sendResponse({ connected: !!port, port, queuedFlushed: sent });
      } else {
        sendResponse({ connected: false, port: null });
      }
    });
    return true;
  }
  if (msg && msg.type === "getVideos") {
    const tabId = sender.tab ? sender.tab.id : -1;
    sendResponse({ videos: sniffActive() ? (tabVideos.get(tabId) || []) : [] });
    return false;
  }
  if (msg && msg.type === "probeSize") {
    probeVideoSize(msg.url).then((size) => sendResponse({ size }));
    return true;
  }
  if (msg && msg.type === "downloadVideo") {
    const raw = {
      url: msg.url,
      filename: msg.filename,
      referer: msg.referer || (sender.tab ? sender.tab.url : undefined),
    };
    enrichPayload(raw).then((payload) => sendToApp(payload)).then(async (ok) => {
      if (!ok) await enqueueTask(raw);
      sendResponse({ ok });
      if (ok) {
        notify("已交给速下", (msg.filename || "视频") + " 正在下载");
      } else {
        notify("速下未运行", "已加入等待队列，速下启动后自动下载。");
      }
    });
    return true;
  }
});

// SW 启动：同步一次 App 端嗅探总开关（必须放在文件末尾 ——
// ensurePort/activePort 等都在前面声明，提前调用会触发 TDZ 引用错误）
syncSniffFromApp();

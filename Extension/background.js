// 速下浏览器接管：同步注册下载监听；冷启动先暂停再读取设置。
// App 离线时通过 Native Messaging 即时启动；只交接当次任务，不保存离线队列。
// 保留文件过滤、身份补全、视频嗅探、右键菜单与 App 端确认设置。

const PORTS = [10007, 10008, 10009, 10010, 10011, 10012, 10013, 10014, 10015, 10016];
const DEFAULTS = { mode: "auto", filter: "all", excluded: "", sniff: true, sniffApp: true };
const ACTIVE_PORT_KEY = "qd_active_port";
const QUEUE_KEY = "qd_pending_queue";
const HANDOFF_TTL = 3000;
const LAUNCH_TTL = 12000;
const NATIVE_HOST = "com.quickdown.bridge";
let launching = null;

// ============================================================================
// 设置：内存预加载（hot path 绝不读 storage）
// ============================================================================

let settings = { ...DEFAULTS };
let settingsReady = false;

// SW 启动时立即加载；下载接管在设置就绪前先暂停。
const settingsLoaded = new Promise((resolve) => {
  chrome.storage.sync.get(DEFAULTS, (s) => {
    void chrome.runtime.lastError;
    settings = { ...DEFAULTS, ...s };
    settingsReady = true;
    resolve();
  });
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
    const response = await localRequest(port, "/sniff", {}, 1500);
    if (!response.ok) return;
    const on = response.text.trim() !== "off";
    const cur = await chrome.storage.sync.get({ sniffApp: true });
    if (cur.sniffApp !== on) await chrome.storage.sync.set({ sniffApp: on });
  } catch {}
}

// ============================================================================
// 即时连接：并行发现 + 合并并发探测。缓存只作优先候选，每次都验证 App 身份。
// 不依赖保活定时器，不在后台扫描或补发下载。
// ============================================================================

let activePort = null;
let discovery = null;

async function localRequest(port, path, options = {}, timeout = 500) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  try {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      ...options, signal: ctrl.signal, cache: "no-store",
    });
    const text = await response.text();
    return { ok: response.ok, text };
  } finally {
    clearTimeout(timer);
  }
}

async function probeApp(port) {
  try {
    const response = await localRequest(port, "/integration");
    if (!response.ok) return null;
    const info = JSON.parse(response.text);
    if (info.name !== "QuickDown" || info.protocol !== 2 ||
        typeof info.session !== "string" || !info.session ||
        !Number.isFinite(info.startedAt)) return null;
    return { port, session: info.session, startedAt: info.startedAt };
  } catch { return null; }
}

async function findConnection() {
  if (discovery) return discovery;
  discovery = (async () => {
    // 同时探测，避免失效缓存拖慢第一笔下载。
    const ports = activePort ? [activePort, ...PORTS.filter(p => p !== activePort)] : PORTS;
    const connection = await new Promise((resolve) => {
      let remaining = ports.length;
      let settled = false;
      for (const port of ports) {
        probeApp(port).then((result) => {
          if (settled) return;
          if (result) { settled = true; resolve(result); }
          else if (--remaining === 0) resolve(null);
        });
      }
    });
    activePort = connection ? connection.port : null;
    return connection;
  })();
  try { return await discovery; }
  finally { discovery = null; }
}

async function ensurePort() {
  const connection = await findConnection();
  return connection ? connection.port : null;
}

// 升级时清除旧版离线队列，包括旧版 session 不可用时写入 local 的队列。
for (const store of [chrome.storage.session, chrome.storage.local]) {
  if (store) store.remove([QUEUE_KEY, ACTIVE_PORT_KEY]).catch(() => {});
}

function discardNotice() {
  notify("下载未交给速下", "无法启动或连接速下，本次下载已丢弃。请安装新版 App 并打开一次，再重新点击下载。");
}

// 合并同时到来的启动请求。浏览器只传启动指令，不把 URL/Cookie 写入原生主机。
async function launchApp() {
  if (launching) return launching;
  launching = new Promise((resolve) => {
    let settled = false;
    const finish = (connection) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(connection);
    };
    const timer = setTimeout(() => finish(null), 10000);
    try {
      chrome.runtime.sendNativeMessage(NATIVE_HOST, { action: "launch" }, (response) => {
        const error = chrome.runtime.lastError;
        if (error || !response || !response.ok || response.name !== "QuickDown" ||
            response.protocol !== 2 || !PORTS.includes(response.port) ||
            typeof response.session !== "string" || !response.session ||
            !Number.isFinite(response.startedAt)) { finish(null); return; }
        activePort = response.port;
        finish({ port: response.port, session: response.session, startedAt: response.startedAt });
      });
    } catch { finish(null); }
  });
  try { return await launching; }
  finally { launching = null; }
}

// 状态检查/嗅探同步只探测；只有明确的下载或“打开 App”操作才启动应用。
async function handoff(payload, capturedAt = Date.now(), connectionPromise = findConnection()) {
  try {
    if (typeof payload.url !== "string" || !["http:", "https:"].includes(new URL(payload.url).protocol)) return false;
  } catch { return false; }
  let connection = await connectionPromise;
  let sendAt = capturedAt;
  if (!connection) {
    if (Date.now() - capturedAt > HANDOFF_TTL) return false;
    connection = await launchApp();
    if (!connection || Date.now() - capturedAt > LAUNCH_TTL) return false;
    // 明确的启动操作成功后，只给当次请求签发新的短期交接时间。
    // /add 仍绑定刚启动的 App 会话，重启/迟到请求不能进入以后启动的 App。
    sendAt = Date.now();
  } else if (connection.startedAt > capturedAt) {
    // App 在当次探测期间自行启动，按当前会话即时交接。
    sendAt = Date.now();
  }
  if (Date.now() - capturedAt > LAUNCH_TTL || Date.now() - sendAt > HANDOFF_TTL) return false;
  await enrichPayload(payload);
  return sendToApp(payload, connection, sendAt);
}

// ============================================================================
// 文件名推导
// ============================================================================

// onCreated 的 filename 可能尚未填好。响应头先于下载事件到达，短时保存真实名称。
// 这里只缓存响应元数据，不缓存下载任务；关闭视频嗅探时也保持有效。
const responseNames = new Map();
function responseFilename(headers) {
  const value = (headers || []).find(h => h.name.toLowerCase() === "content-disposition")?.value || "";
  const encoded = /filename\*\s*=\s*(?:"([^"\r\n]+)"|([^;\r\n]+))/i.exec(value);
  if (encoded) {
    const match = /^UTF-8'[^']*'(.*)$/i.exec((encoded[1] || encoded[2]).trim());
    if (match) { try { return decodeURIComponent(match[1]); } catch {} }
  }
  const plain = /filename\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^;\r\n]+))/i.exec(value);
  return plain ? (plain[1] || plain[2] || "").replace(/\\(.)/g, "$1").trim() : "";
}
chrome.webRequest.onHeadersReceived.addListener((details) => {
  const filename = responseFilename(details.responseHeaders);
  if (!filename) { responseNames.delete(details.url); return; }
  responseNames.set(details.url, { filename, at: Date.now() });
  if (responseNames.size > 256) responseNames.delete(responseNames.keys().next().value);
}, { urls: ["http://*/*", "https://*/*"] }, ["responseHeaders"]);

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
  const response = responseNames.get(urlStr);
  if (response && Date.now() - response.at < 30000 &&
      (!provided || provided === pathBase || isHashName(provided))) {
    return response.filename.replace(/^.*[\\/]/, "").trim();
  }
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

async function sendToApp(item, connection, capturedAt) {
  const remaining = HANDOFF_TTL - (Date.now() - capturedAt);
  if (!connection || remaining <= 0) return false;
  try {
    const response = await localRequest(connection.port, "/add", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-QuickDown-Session": connection.session,
        "X-QuickDown-Captured-At": String(capturedAt),
      },
      body: JSON.stringify({
        url: item.url, filename: item.filename || undefined,
        referer: item.referer || undefined, userAgent: item.userAgent || undefined,
        cookie: item.cookie || undefined,
      }),
    }, Math.min(1500, remaining));
    return response.ok;
  } catch { return false; }
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
    const extOk = MEDIA_RE.test(deriveFilename(item) || url);
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
// 浏览器已完成下载。既然用户要求拦截，这里删除磁盘文件并抹掉下载历史，
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
// 核心接管：设置已加载时立即 cancel；冷启动先 pause 再校验设置。
// ============================================================================

async function takeOver(downloadItem, opts = {}) {
  const capturedAt = Date.now();
  // 冷启动时不能拿默认设置接管：先暂停，等真实设置；关闭/排除的下载恢复。
  let paused = false;
  if (!settingsReady) {
    try { await chrome.downloads.pause(downloadItem.id); paused = true; } catch {}
    await settingsLoaded;
  }
  if (settings.mode === "off" || !shouldCapture(downloadItem)) {
    if (paused) { try { await chrome.downloads.resume(downloadItem.id); } catch {} }
    return;
  }

  const url = downloadItem.finalUrl || downloadItem.url;
  if (!markCaptured(downloadItem.id)) return;

  const payload = {
    url,
    filename: deriveFilename(downloadItem),
    referer: downloadItem.referrer,
    // 注意：DownloadItem 没有 userAgent 字段（此前写的 downloadItem.userAgent
    // 恒为 undefined），统一由 enrichPayload 用浏览器真实 UA 补全
  };

  // 先发出取消，再并行探测 App，避免网络工作延迟浏览器拦截。
  const cancellation = new Promise((resolve) => {
    try {
      chrome.downloads.cancel(downloadItem.id, () => {
        void chrome.runtime.lastError;
        resolve();
      });
    } catch { resolve(); }
  });
  const connectionPromise = findConnection();
  await cancellation;
  const delivery = handoff(payload, capturedAt, connectionPromise);

  if (opts.eraseFromHistory) {
    // 先删磁盘文件再抹历史：若 cancel 输给了极小文件（浏览器已完成），
    // removeFile 在这里直接清掉文件 —— 不能依赖 onChanged 里的 removeFile，
    // 因为下面的 erase 抹掉条目后，该下载的后续事件可能不再派发，文件会残留在磁盘
    try { await chrome.downloads.removeFile(downloadItem.id); } catch (e) {}
    try { await chrome.downloads.erase({ id: downloadItem.id }); } catch (e) {}
  }

  // cancel 输给完成事件时仍按当次请求处理；离线不保留。
  const ok = await delivery;
  if (!ok) discardNotice();
}

// 下载事件在顶层同步注册，Chrome 可在 SW 冷启动时派发。
chrome.downloads.onCreated.addListener((item) => {
  void takeOver(item, { eraseFromHistory: true });
});

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
  settingsLoaded.then(createMenus);
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
  const ok = await handoff(payload);
  if (ok) {
    notify("已交给速下", "下载已添加到速下。");
  } else {
    discardNotice();
  }
});

// alarm 只同步设置，不接管历史下载，也不保存/补发任务。
function ensureKeepaliveAlarm() {
  chrome.alarms.create("qd-keepalive", { periodInMinutes: 0.5 });
}
chrome.runtime.onInstalled.addListener(ensureKeepaliveAlarm);
chrome.runtime.onStartup.addListener(ensureKeepaliveAlarm);
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "qd-keepalive") void syncSniffFromApp();
});

// ============================================================================
// 消息处理
// ============================================================================

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "openApp") {
    (async () => {
      const connection = await findConnection() || await launchApp();
      if (!connection) { sendResponse({ ok: false }); return; }
      try {
        const response = await localRequest(connection.port, "/activate", {}, 1500);
        sendResponse({ ok: response.ok });
      } catch { sendResponse({ ok: false }); }
    })();
    return true;
  }
  if (msg && msg.type === "getStatus") {
    ensurePort().then((port) => sendResponse({ connected: !!port, port }));
    return true;
  }
  if (msg && msg.type === "recheck") {
    activePort = null;
    ensurePort().then((port) => sendResponse({ connected: !!port, port }));
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
    handoff(raw).then((ok) => {
      sendResponse({ ok });
      if (ok) {
        notify("已交给速下", (msg.filename || "视频") + " 正在下载");
      } else {
        discardNotice();
      }
    });
    return true;
  }
});

// SW 启动：同步一次 App 端嗅探总开关（必须放在文件末尾 ——
// ensurePort/activePort 等都在前面声明，提前调用会触发 TDZ 引用错误）
settingsLoaded.then(() => syncSniffFromApp());

// 速下 - 浏览器下载接管 后台服务
//
// 接管灵敏度核心设计（参考 Ghost-Downloader-3）：
// 0. SW 常驻保活：MV3 SW 空闲约 30 秒会被休眠，休眠期间下载到来需要先唤醒 SW，
//    唤醒耗时内浏览器原生下载已在进行，快速网络下 cancel 执行前文件可能已完成。
//    每 20 秒调用一次轻量扩展 API 重置空闲计时器，让 SW 永不休眠，
//    onCreated → cancel 稳定在毫秒级执行 —— 这是 100% 接管的关键。
// 1. 设置在 SW 启动时预加载到内存，事件 hot path 零异步读取
// 2. onDeterminingFilename + onCreated 双事件兜底，cancel 之前零 await
// 3. 并行端口发现 + 活跃端口持久化
// 4. 任务队列：速下未启动时暂存，启动后自动补发
// 5. alarms 定期保活 + 队列 flush
// 6. onChanged 兜底：极小文件在 cancel 落地前已被浏览器下载完成时，
//    删除磁盘文件并抹掉下载历史（任务早已发给速下），不留浏览器下载痕迹
// 7. SW 启动时清扫接管浏览器中已在进行中的下载（扩展刚装载 / 浏览器恢复场景）

const PORTS = [10007, 10008, 10009, 10010, 10011, 10012, 10013, 10014, 10015, 10016];
const DEFAULTS = { mode: "auto", filter: "all", excluded: "" };
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
  for (const [key, change] of Object.entries(changes)) {
    if (key in DEFAULTS) settings[key] = change.newValue;
  }
});

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

const MEDIA_RE = /\.(mp4|mkv|avi|mov|flv|webm|ts|m4v|mpg|mpeg|mp3|wav|flac|aac|ogg|m4a|wma|zip|rar|7z|tar|gz|bz2|xz|dmg|pkg|iso|apk|exe|msi|pdf|doc|docx|xls|xlsx|ppt|pptx)(\?|#|$)/i;
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
    chrome.notifications.create({
      type: "basic",
      iconUrl: "icons/icon128.png",
      title,
      message,
    });
  } catch (e) {}
}

// ============================================================================
// 去重 + 兜底清理（同步）
// ============================================================================

// 已接管的 download id：同一 item 的重复事件只发一次任务
// （按 id 而不是按 url 去重 —— 按 url 去重会误杀 8 秒内的重复下载，
//  把第二次下载白白放给浏览器）
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
    capturedIds.delete(delta.id);
    (async () => {
      try { await chrome.downloads.removeFile(delta.id); } catch (e) {}
      try { await chrome.downloads.erase({ id: delta.id }); } catch (e) {}
    })();
  } else if (state === "canceled" || state === "interrupted") {
    capturedIds.delete(delta.id);
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

  const filename = downloadItem.filename || "";
  const payload = {
    url,
    filename,
    referer: downloadItem.referrer,
    userAgent: downloadItem.userAgent,
  };

  // ask 模式：弹通知
  if (settings.mode === "ask") {
    notifyAsk(downloadItem, payload);
    return;
  }

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
    try { await chrome.downloads.erase({ id: downloadItem.id }); } catch (e) {}
  }

  // 如果 cancel 失败（下载可能已完成），仍交给速下（与 Ghost 行为一致）
  const ok = await sendToApp(payload);
  if (!ok) {
    await enqueueTask(payload);
  }
}

function notifyAsk(item, payload) {
  const id = "qd-ask-" + item.id;
  const name = payload.filename || item.filename || "文件";
  chrome.notifications.create(id, {
    type: "basic",
    iconUrl: "icons/icon128.png",
    title: "发现下载：" + name,
    message: "要用速下接管这个下载吗？",
    buttons: [{ title: "用速下下载" }, { title: "放弃（浏览器下载）" }],
  });

  const handler = async (nid, buttonIndex) => {
    if (nid !== id) return;
    chrome.notifications.onButtonClicked.removeListener(handler);
    if (buttonIndex === 0) {
      try { await chrome.downloads.cancel(item.id); } catch (e) {}
      try { await chrome.downloads.erase({ id: item.id }); } catch (e) {}
      const ok = await sendToApp(payload);
      if (ok) {
        notify("已交给速下", name + " 已添加到速下。");
      } else {
        await enqueueTask(payload);
        notify("速下未运行", "已加入等待队列，速下启动后自动下载。");
      }
    }
  };
  chrome.notifications.onButtonClicked.addListener(handler);
}

// ============================================================================
// 下载事件监听
//
// 策略：
// - SW 常驻保活（见文件头），onCreated 到达即毫秒级处理，浏览器下载来不及开始
// - onCreated：100% 触发，负责完整接管逻辑（检查、去重、cancel、发任务）
// - onDeterminingFilename：MV3 SW 上不可靠（经常不触发），只做额外的 cancel
//   （先 cancel 再 suggest，浏览器在等 suggest 期间下载暂停，cancel 更干净）
// - onChanged：极小文件在 cancel 落地前已完成时，删除文件 + 抹掉历史（见上方兜底）
// - SW 启动清扫：接管浏览器中已在进行中的下载（扩展装载/更新瞬间的漏网之鱼）
// ============================================================================

const supportsDetermining = typeof chrome.downloads?.onDeterminingFilename?.addListener === "function";

// 组装下载任务 payload（同步）
function buildPayload(item) {
  return {
    url: item.finalUrl || item.url,
    filename: item.filename || "",
    referer: item.referrer,
    userAgent: item.userAgent,
  };
}

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

// ---- onDeterminingFilename：能触发时是更早的拦截点（MV3 上经常不触发，仅作增强）----
// 该事件触发时下载正暂停在"等待文件名"阶段，此时 cancel 最干净。
// 与 onCreated 都走完整 takeOver，由 markCaptured 按 id 去重：谁先触发谁生效，
// 另一个自动跳过 —— 双保险，任何一边失效都不影响接管。
if (supportsDetermining) {
  chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
    let suggested = false;
    const doSuggest = () => {
      if (!suggested) { suggested = true; suggest(); }
    };
    // 安全超时：3 秒内必须 suggest
    const safetyTimer = setTimeout(doSuggest, 3000);

    // 只对应该接管的下载做接管
    if (settings.mode === "off" || !shouldCapture(item)) {
      clearTimeout(safetyTimer);
      doSuggest();
      return;
    }

    (async () => {
      try { await takeOver(item, { eraseFromHistory: true }); } catch (e) {}
      clearTimeout(safetyTimer);
      doSuggest();
    })();
  });
}

// ============================================================================
// 视频嗅探
// ============================================================================

const VIDEO_URL_RE = /\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)(\?|#|$)/i;
const tabVideos = new Map();

chrome.webRequest.onBeforeRequest.addListener((details) => {
  if (details.tabId < 0) return;
  const url = details.url;
  if (!VIDEO_URL_RE.test(url)) return;
  if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) return;
  const m = url.toLowerCase().match(/\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)/);
  const type = m ? m[1] : "media";
  let list = tabVideos.get(details.tabId);
  if (!list) {
    list = [];
    tabVideos.set(details.tabId, list);
  }
  if (!list.some((v) => v.url === url)) {
    list.push({ url, type });
    if (list.length > 200) list.shift();
  }
}, { urls: ["<all_urls>"] });

chrome.tabs.onRemoved.addListener((tabId) => tabVideos.delete(tabId));

// ============================================================================
// 右键菜单
// ============================================================================

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "qd-link", title: "用速下下载此链接", contexts: ["link"] });
    chrome.contextMenus.create({ id: "qd-media", title: "用速下下载此媒体", contexts: ["video", "audio"] });
    chrome.contextMenus.create({ id: "qd-image", title: "用速下下载此图片", contexts: ["image"] });
    chrome.contextMenus.create({ id: "qd-page", title: "用速下下载当前页面", contexts: ["page"] });
    chrome.contextMenus.create({ id: "qd-sniff", title: "🎬 嗅探本页视频", contexts: ["page"] });
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "qd-sniff") {
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
    sendResponse({ videos: tabVideos.get(tabId) || [] });
    return false;
  }
  if (msg && msg.type === "downloadVideo") {
    const payload = {
      url: msg.url,
      filename: msg.filename,
      referer: msg.referer || (sender.tab ? sender.tab.url : undefined),
    };
    sendToApp(payload).then(async (ok) => {
      if (!ok) await enqueueTask(payload);
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

// 速下 - 浏览器下载接管 后台服务
// 负责：发现本地服务端口、把下载交给速下、右键菜单

const PORTS = [10007, 10008, 10009, 10010, 10011, 10012, 10013, 10014];
const DEFAULTS = { mode: "auto", filter: "all", excluded: "" };

let activePort = null;
let lastPingTime = 0;

// ---------- 设置 ----------

function getSettings() {
  return new Promise((resolve) => {
    chrome.storage.sync.get(DEFAULTS, resolve);
  });
}

// ---------- 端口发现 ----------

async function ping(port) {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 600);
    const r = await fetch(`http://127.0.0.1:${port}/ping`, { signal: ctrl.signal });
    clearTimeout(t);
    return r.ok && (await r.text()) === "ok";
  } catch {
    return false;
  }
}

async function findPort() {
  for (const p of PORTS) {
    if (await ping(p)) {
      activePort = p;
      return p;
    }
  }
  activePort = null;
  return null;
}

async function ensurePort() {
  const now = Date.now();
  if (activePort && now - lastPingTime < 5000) {
    if (await ping(activePort)) return activePort;
  }
  lastPingTime = now;
  return findPort();
}

// ---------- 交给速下 ----------

async function sendToApp(item) {
  const port = await ensurePort();
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

// ---------- 过滤 ----------

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

function shouldCapture(item, settings) {
  const url = item.url;
  if (!url.startsWith("http://") && !url.startsWith("https://")) return false;
  if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) return false;
  if (isExcluded(url, settings.excluded)) return false;
  if (settings.filter === "media") {
    const mimeOk = item.mime && MEDIA_MIME.test(item.mime);
    const extOk = MEDIA_RE.test(item.filename || url);
    if (!mimeOk && !extOk) return false;
  }
  return true;
}

// ---------- 通知 ----------

function notify(title, message) {
  try {
    chrome.notifications.create({
      type: "basic",
      iconUrl: "icons/icon128.png",
      title,
      message,
    });
  } catch (e) {
    /* 忽略 */
  }
}

// ---------- 下载拦截 ----------

// 防循环：短时间内同一 URL 只拦截一次（防止交给速下失败后回退重新下载导致无限循环动画）
const recentCaptures = new Map(); // url -> 时间戳
function markCaptured(url) {
  const now = Date.now();
  if (recentCaptures.get(url) && now - recentCaptures.get(url) < 8000) return false;
  recentCaptures.set(url, now);
  if (recentCaptures.size > 200) {
    for (const [k, v] of recentCaptures) {
      if (now - v > 8000) recentCaptures.delete(k);
    }
  }
  return true;
}

// 记录"最终文件名"：onDeterminingFilename 在服务器响应头（Content-Disposition）
// 解析完成后触发，此时的文件名才是真实名字（而非 URL 推导的哈希/通用名）
const resolvedNames = new Map(); // downloadId -> filename
chrome.downloads.onDeterminingFilename.addListener((item) => {
  if (item && item.filename) {
    resolvedNames.set(item.id, item.filename);
    // 清理：id 对应的下载完成后移除
    setTimeout(() => resolvedNames.delete(item.id), 60000);
  }
  // 不调用 suggest()：保持浏览器默认命名
});

// 当前文件名是否需要等待解析（哈希名 / 通用名 / 无扩展名）
function needsBetterName(name) {
  if (!name) return true;
  const base = name.replace(/\.[^.]+$/, "");
  const hex = /^[0-9a-f]{32}$/i.test(base) || /^[0-9a-f]{40}$/i.test(base);
  const generic = /^(file|download|index|default|unnamed)(\..*)?$/i.test(name);
  return hex || generic || !/\./.test(name);
}

// 等待文件名解析完成（最多 1.5 秒）
async function waitResolvedName(item, timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const name = resolvedNames.get(item.id);
    if (name) return name;
    try {
      const found = await chrome.downloads.search({ id: item.id });
      if (found.length && found[0].filename) return found[0].filename;
    } catch (e) {}
    await new Promise((r) => setTimeout(r, 100));
  }
  return item.filename;
}

chrome.downloads.onCreated.addListener(async (item) => {
  const settings = await getSettings();
  if (settings.mode === "off") return;
  if (!shouldCapture(item, settings)) return;
  if (!markCaptured(item.url)) return; // 防循环

  // 等待真实文件名解析（避免哈希/通用名），同时拿到最终 URL
  let filename = item.filename;
  let url = item.url;
  if (needsBetterName(filename)) {
    const waitMs = settings.mode === "ask" ? 2000 : 1500;
    const resolved = await waitResolvedName(item, waitMs);
    if (resolved) filename = resolved;
    try {
      const found = await chrome.downloads.search({ id: item.id });
      if (found.length && (found[0].finalUrl || found[0].url)) {
        url = found[0].finalUrl || found[0].url;
      }
    } catch (e) {}
  }

  if (settings.mode === "ask") {
    notifyAsk(item, filename);
    return;
  }

  // 自动接管：立即取消浏览器下载（减少浏览器下载动画停留），同时交给速下
  // 若交给速下失败，则回退让浏览器重新下载，避免丢失文件
  const port = await ensurePort(); // 有缓存，通常立即返回
  if (!port) return; // 速下未运行，不拦截
  const p = sendToApp({ url, filename, referer: item.referrer, userAgent: item.userAgent }); // 不等待，先取消
  try { await chrome.downloads.cancel(item.id); } catch (e) {}
  try { await chrome.downloads.erase({ id: item.id }); } catch (e) {}
  const ok = await p;
  if (!ok) {
    // 回退：让浏览器重新下载
    try {
      await chrome.downloads.download({
        url: url,
        filename: filename || undefined,
      });
    } catch (e) {}
  }
});

function notifyAsk(item, filename) {
  const id = "qd-ask-" + item.id;
  const name = filename || item.filename || "文件";
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
      const ok = await sendToApp({
        url: item.url,
        filename: filename || item.filename,
        referer: item.referrer,
        userAgent: item.userAgent,
      });
      if (ok) {
        try { await chrome.downloads.cancel(item.id); } catch (e) {}
        try { await chrome.downloads.erase({ id: item.id }); } catch (e) {}
        notify("已交给速下", name + " 已添加到速下。");
      } else {
        notify("速下未运行", "请先打开速下应用。");
      }
    }
  };
  chrome.notifications.onButtonClicked.addListener(handler);
}

// ---------- 视频嗅探（webRequest 收集） ----------

const VIDEO_URL_RE = /\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)(\?|#|$)/i;
const tabVideos = new Map(); // tabId -> [{url, type}]

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

// ---------- 右键菜单 ----------

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
  const ok = await sendToApp({
    url,
    filename: undefined,
    referer: tab ? tab.url : undefined,
  });
  if (ok) {
    notify("已交给速下", "下载已添加到速下。");
  } else {
    notify("速下未运行", "请先打开速下应用，再使用右键下载。");
  }
});

// ---------- 消息（弹窗 / 选项页 / 内容脚本） ----------

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "getStatus") {
    ensurePort().then((port) => sendResponse({ connected: !!port, port }));
    return true; // 异步响应
  }
  if (msg && msg.type === "recheck") {
    activePort = null;
    ensurePort().then((port) => sendResponse({ connected: !!port, port }));
    return true;
  }
  if (msg && msg.type === "getVideos") {
    const tabId = sender.tab ? sender.tab.id : -1;
    sendResponse({ videos: tabVideos.get(tabId) || [] });
    return false;
  }
  if (msg && msg.type === "downloadVideo") {
    sendToApp({
      url: msg.url,
      filename: msg.filename,
      referer: msg.referer || (sender.tab ? sender.tab.url : undefined),
    }).then((ok) => {
      sendResponse({ ok });
      if (ok) {
        notify("已交给速下", (msg.filename || "视频") + " 正在下载");
      } else {
        notify("速下未运行", "请先打开速下应用，再点击下载。");
      }
    });
    return true; // 异步响应
  }
});

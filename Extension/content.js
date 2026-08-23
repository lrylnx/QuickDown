// 速下 - 网页视频嗅探
// 浮动按钮 + 面板：收集页面内可下载的视频资源（m3u8 / ts / mp4 / flv 等）

(() => {
  if (window.top !== window) return; // 只在顶层页面显示
  if (location.protocol !== "http:" && location.protocol !== "https:") return;

  const VIDEO_URL_RE = /\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)(\?|#|$)/i;

  let rootEl = null;
  let panelEl = null;
  let lastKey = "";

  function guessName(url) {
    try {
      const u = new URL(url);
      const name = decodeURIComponent(u.pathname.split("/").pop() || "");
      return name || undefined;
    } catch (e) {
      return undefined;
    }
  }

  function scanDom() {
    const found = [];
    document.querySelectorAll("video, source, a[href]").forEach((el) => {
      const src = el.currentSrc || el.src || el.href ||
        el.getAttribute("src") || el.getAttribute("href");
      if (src && VIDEO_URL_RE.test(src)) {
        let full = src;
        if (src.startsWith("//")) full = location.protocol + src;
        if (full.startsWith("http")) found.push(full);
      }
    });
    try {
      performance.getEntriesByType("resource").forEach((e) => {
        if (VIDEO_URL_RE.test(e.name)) found.push(e.name);
      });
    } catch (e) {}
    return found;
  }

  async function collect() {
    const dom = scanDom();
    let bg = [];
    try {
      const resp = await chrome.runtime.sendMessage({ type: "getVideos" });
      bg = (resp && resp.videos) || [];
    } catch (e) {}
    const map = new Map();
    dom.forEach((u) => map.set(u, u));
    bg.forEach((v) => map.set(v.url, v.url));
    return [...map.keys()];
  }

  function typeOf(url) {
    const m = url.match(/\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)/i);
    return m ? m[1].toUpperCase() : "媒体";
  }

  function ensureRoot() {
    if (rootEl && document.body.contains(rootEl)) return;
    rootEl = document.createElement("div");
    rootEl.id = "qd-sniff-root";
    rootEl.style.cssText =
      "position:fixed;bottom:16px;right:16px;z-index:2147483647;" +
      "font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;";
    document.body.appendChild(rootEl);
  }

  function togglePanel() {
    if (panelEl) {
      panelEl.remove();
      panelEl = null;
    } else {
      renderPanel();
    }
  }

  function renderPanel() {
    if (!panelEl) {
      panelEl = document.createElement("div");
      panelEl.style.cssText =
        "background:#fff;border:1px solid #ddd;border-radius:12px;" +
        "box-shadow:0 6px 24px rgba(0,0,0,.18);width:340px;max-height:440px;" +
        "overflow:auto;color:#1d1d1f;margin-bottom:8px;";
      rootEl.appendChild(panelEl);
    }
    panelEl.innerHTML = "";
    const title = document.createElement("div");
    title.style.cssText =
      "padding:10px 12px;font-weight:600;font-size:13px;border-bottom:1px solid #eee;" +
      "display:flex;justify-content:space-between;align-items:center;position:sticky;top:0;background:#fff;";
    const titleSpan = document.createElement("span");
    titleSpan.textContent = "🎬 速下视频嗅探";
    const close = document.createElement("span");
    close.textContent = "✕";
    close.style.cssText = "cursor:pointer;color:#999;padding:2px 6px;";
    close.onclick = () => {
      if (panelEl) {
        panelEl.remove();
        panelEl = null;
      }
    };
    title.append(titleSpan, close);
    panelEl.appendChild(title);

    if (!lastVideos.length) {
      const empty = document.createElement("div");
      empty.textContent = "未检测到视频资源";
      empty.style.cssText = "padding:16px;font-size:12px;color:#888;text-align:center;";
      panelEl.appendChild(empty);
      return;
    }

    lastVideos.forEach((url) => {
      const type = typeOf(url);
      const row = document.createElement("div");
      row.style.cssText =
        "padding:8px 12px;border-bottom:1px solid #f5f5f5;display:flex;align-items:center;gap:8px;";
      const badge = document.createElement("span");
      badge.textContent = type;
      badge.style.cssText =
        "font-size:10px;background:#2e9e44;color:#fff;border-radius:4px;padding:1px 5px;flex-shrink:0;";
      const name = document.createElement("span");
      name.textContent = url.length > 44 ? url.slice(0, 44) + "…" : url;
      name.style.cssText =
        "font-size:12px;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;";
      name.title = url;
      const btn = document.createElement("button");
      btn.textContent = "下载";
      btn.style.cssText =
        "font-size:12px;background:#2e9e44;color:#fff;border:none;border-radius:6px;" +
        "padding:4px 10px;cursor:pointer;flex-shrink:0;";
      btn.onclick = async () => {
        btn.disabled = true;
        btn.textContent = "…";
        let filename;
        if (type === "M3U8") {
          filename = (document.title || "video")
            .replace(/[\\/:*?"<>|\n]/g, "_").trim().slice(0, 60) + ".mp4";
        } else {
          filename = guessName(url);
        }
        try {
          const resp = await chrome.runtime.sendMessage({ type: "downloadVideo", url, filename });
          const ok = resp && resp.ok;
          btn.textContent = ok ? "✓ 已接管" : "失败";
          btn.style.background = ok ? "#1f7a33" : "#d33";
          btn.disabled = false;
        } catch (e) {
          btn.textContent = "失败";
          btn.style.background = "#d33";
          btn.disabled = false;
        }
      };
      row.append(badge, name, btn);
      panelEl.appendChild(row);
    });
  }

  let lastVideos = [];

  async function refresh() {
    const videos = await collect();
    const key = videos.join("\n");
    if (key !== lastKey) {
      lastKey = key;
      lastVideos = videos;
      ensureRoot();
      // 浮动按钮
      rootEl.innerHTML = "";
      if (!videos.length) {
        if (panelEl) {
          panelEl.remove();
          panelEl = null;
        }
        return;
      }
      const btn = document.createElement("button");
      btn.textContent = "🎬 " + videos.length;
      btn.title = "速下视频嗅探：发现 " + videos.length + " 个视频资源";
      btn.style.cssText =
        "background:#2e9e44;color:#fff;border:none;border-radius:999px;" +
        "padding:8px 14px;font-size:13px;cursor:pointer;box-shadow:0 4px 14px rgba(0,0,0,.25);";
      btn.onclick = togglePanel;
      rootEl.appendChild(btn);
      if (panelEl) {
        panelEl.remove();
        panelEl = null;
      }
    }
  }

  // 右键菜单「嗅探本页视频」→ 打开面板
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === "showPanel") {
      ensureRoot();
      renderPanel();
    }
  });

  setInterval(refresh, 4000);
  refresh();
})();

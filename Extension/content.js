// 速下 - 网页视频嗅探
// 悬浮嗅探按钮：鼠标悬停到视频上时出现在视频右上角（含分辨率 / 大小），
// 移开消失；视频全屏时不出现。右键菜单「嗅探本页视频」仍可打开列表面板。

(() => {
  if (location.protocol !== "http:" && location.protocol !== "https:") return;

  const VIDEO_URL_RE = /\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)(\?|#|$)/i;
  const TOP = window.top === window;   // 列表面板只在顶层页面
  const MIN_W = 160, MIN_H = 100;      // 小于该尺寸的 video 视为贴片/装饰，不出按钮

  let hoverBtn = null;
  let hoveredVideo = null;
  let lastMoveAt = 0;
  const sizeCache = new Map();         // url -> number|null（探测失败也缓存）

  function guessName(url) {
    try {
      const u = new URL(url);
      const name = decodeURIComponent(u.pathname.split("/").pop() || "");
      return name || undefined;
    } catch (e) {
      return undefined;
    }
  }

  function typeOf(url) {
    const m = url.match(/\.(m3u8|ts|mp4|flv|webm|mkv|mov|m4v|m4s|aac|mp3)/i);
    return m ? m[1].toUpperCase() : "媒体";
  }

  function formatSize(bytes) {
    if (!bytes || bytes <= 0) return null;
    if (bytes >= 1024 ** 3) return (bytes / 1024 ** 3).toFixed(2) + " GB";
    if (bytes >= 1024 ** 2) return (bytes / 1024 ** 2).toFixed(1) + " MB";
    return Math.max(1, Math.round(bytes / 1024)) + " KB";
  }

  // ==========================================================================
  // 悬浮嗅探按钮
  // ==========================================================================

  const BASE_CSS =
    "position:fixed;z-index:2147483647;display:flex;flex-direction:column;gap:2px;" +
    "align-items:center;padding:6px 12px;border:none;border-radius:10px;cursor:pointer;" +
    "background:rgba(20,24,22,.88);color:#fff;box-shadow:0 4px 16px rgba(0,0,0,.35);" +
    "font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;" +
    "line-height:1.35;user-select:none;";

  function ensureBtn() {
    if (hoverBtn && hoverBtn.isConnected) return hoverBtn;
    hoverBtn = document.createElement("button");
    hoverBtn.id = "qd-hover-btn";
    hoverBtn.style.cssText = BASE_CSS + "display:none;";
    hoverBtn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (hoveredVideo) downloadHovered(hoveredVideo);
    });
    // 阻止按钮上的 mousemove 触发隐藏判定抖动
    hoverBtn.addEventListener("mousemove", (e) => e.stopPropagation());
    (document.body || document.documentElement).appendChild(hoverBtn);
    return hoverBtn;
  }

  function hideBtn() {
    if (hoveredVideo) hoveredVideo = null;
    if (hoverBtn) hoverBtn.style.display = "none";
  }

  function resolutionOf(v) {
    let w = v.videoWidth, h = v.videoHeight;
    if (!w || !h) { w = v.clientWidth; h = v.clientHeight; }
    if (!w || !h) return null;
    return w + "×" + h;
  }

  // 探测视频大小：直接媒体地址走后台 Range 请求拿总大小；
  // m3u8 / blob（MSE）流体积未知，不显示大小（undefined=不适用，null=探测失败）
  async function sizeOf(v) {
    let url = v.currentSrc || v.src || "";
    if (!url.startsWith("http")) return undefined;
    if (/\.m3u8(\?|#|$)/i.test(url)) return undefined;
    if (sizeCache.has(url)) return sizeCache.get(url);
    let size = null;
    try {
      const resp = await chrome.runtime.sendMessage({ type: "probeSize", url });
      size = resp && typeof resp.size === "number" ? resp.size : null;
    } catch (e) {}
    sizeCache.set(url, size);
    return size;
  }

  function isHlsVideo(v) {
    const url = v.currentSrc || v.src || "";
    if (/\.m3u8(\?|#|$)/i.test(url)) return true;
    return url.startsWith("blob:"); // MSE（hls.js 等）基本都是 m3u8 流
  }

  function renderBtn(v) {
    const btn = ensureBtn();
    btn.innerHTML = "";
    const row1 = document.createElement("span");
    row1.textContent = "⬇ 下载视频";
    row1.style.cssText = "font-size:13px;font-weight:600;color:#7ee89a;white-space:nowrap;";
    btn.appendChild(row1);

    const info = document.createElement("span");
    const res = resolutionOf(v);
    const isHls = isHlsVideo(v);
    info.textContent = [res, isHls ? "HLS 流 · 合并 MP4" : "…"].filter(Boolean).join(" · ");
    info.style.cssText = "font-size:11px;color:rgba(255,255,255,.85);white-space:nowrap;";
    btn.appendChild(info);

    // 分辨率在元数据加载后可能才可得（videoWidth=0 → 监听一次）
    if (!res) {
      v.addEventListener("loadedmetadata", () => {
        if (hoveredVideo === v && hoverBtn && hoverBtn.isConnected) renderBtn(v);
      }, { once: true });
    }

    // 大小异步到达后补上
    sizeOf(v).then((size) => {
      if (hoveredVideo !== v || !hoverBtn || !hoverBtn.isConnected) return;
      const bytes = formatSize(size);
      if (bytes) info.textContent = [resolutionOf(v), bytes].filter(Boolean).join(" · ");
    });
  }

  function positionBtn(v) {
    const btn = ensureBtn();
    const r = v.getBoundingClientRect();
    btn.style.display = "flex";
    const bw = btn.offsetWidth || 120;
    const bh = btn.offsetHeight || 44;
    let x = r.right - bw - 10;
    let y = r.top + 10;
    x = Math.max(8, Math.min(x, window.innerWidth - bw - 8));
    y = Math.max(8, Math.min(y, window.innerHeight - bh - 8));
    btn.style.left = x + "px";
    btn.style.top = y + "px";
  }

  function videoAt(x, y) {
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      if (r.width < MIN_W || r.height < MIN_H) continue;
      if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
      const st = getComputedStyle(v);
      if (st.visibility === "hidden" || st.display === "none") continue;
      if (parseFloat(st.opacity) < 0.05) continue;
      return v;
    }
    return null;
  }

  function onMove(e) {
    const now = performance.now();
    if (now - lastMoveAt < 60) return;
    lastMoveAt = now;
    if (document.fullscreenElement) { hideBtn(); return; } // 全屏时不出按钮
    const v = videoAt(e.clientX, e.clientY);
    if (!v) { hideBtn(); return; }
    if (v !== hoveredVideo) {
      hoveredVideo = v;
      renderBtn(v);
    }
    positionBtn(v);
  }

  // blob:（MSE/hls.js）拿不到真实地址 → 用后台 webRequest 捕获的媒体地址代替
  async function pickUrl(v) {
    let url = v.currentSrc || v.src || "";
    if (url.startsWith("http")) return url;
    try {
      const resp = await chrome.runtime.sendMessage({ type: "getVideos" });
      const list = (resp && resp.videos) || [];
      if (!list.length) return null;
      const score = (u) =>
        (/\.m3u8(\?|#|$)/i.test(u) ? 3 : /\.(mp4|webm|mkv|mov|m4v|flv)(\?|#|$)/i.test(u) ? 2 : 1);
      const items = list.map((x) => (typeof x === "string" ? { url: x } : x));
      items.sort((a, b) => score(b.url) - score(a.url));
      return items[0].url || null;
    } catch (e) {
      return null;
    }
  }

  async function downloadHovered(v) {
    const btn = ensureBtn();
    const row = btn.querySelector("span");
    if (row) { row.textContent = "⏳ 正在交给速下…"; }
    const url = await pickUrl(v);
    if (!url) {
      if (row) { row.textContent = "✕ 未找到视频地址"; }
      setTimeout(() => { if (hoveredVideo) renderBtn(hoveredVideo); }, 1500);
      return;
    }
    const isHls = /\.m3u8(\?|#|$)/i.test(url);
    const filename = isHls
      ? (document.title || "video").replace(/[\\/:*?"<>|\n]/g, "_").trim().slice(0, 60) + ".mp4"
      : guessName(url);
    try {
      await chrome.runtime.sendMessage({ type: "downloadVideo", url, filename });
      if (row) { row.textContent = "✓ 已交给速下"; }
    } catch (e) {
      if (row) { row.textContent = "✕ 发送失败"; }
    }
    setTimeout(() => { if (hoveredVideo) renderBtn(hoveredVideo); }, 1500);
  }

  document.addEventListener("mousemove", onMove, { capture: true, passive: true });
  // 滚动时视频位置变化：仍悬停则跟随，否则隐藏
  document.addEventListener("scroll", () => {
    if (!hoveredVideo || !hoverBtn || hoverBtn.style.display === "none") return;
    const r = hoveredVideo.getBoundingClientRect();
    if (r.width < MIN_W || r.height < MIN_H || r.bottom < 0 || r.top > window.innerHeight) {
      hideBtn();
    } else {
      positionBtn(hoveredVideo);
    }
  }, { capture: true, passive: true });
  // 进入全屏立即隐藏
  document.addEventListener("fullscreenchange", hideBtn, { capture: true });
  // 兜底：视频被移除/隐藏时清掉按钮（鼠标不动 mousemove 不触发的场景）
  setInterval(() => {
    if (!hoveredVideo || !hoverBtn || hoverBtn.style.display === "none") return;
    const r = hoveredVideo.getBoundingClientRect();
    if (!hoveredVideo.isConnected || r.width < MIN_W || r.height < MIN_H ||
        document.fullscreenElement) {
      hideBtn();
    }
  }, 1000);

  // ==========================================================================
  // 列表面板（右键菜单「嗅探本页视频」打开，仅顶层页面）
  // ==========================================================================

  let rootEl = null;
  let panelEl = null;
  let lastVideos = [];

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
    const map = new Map();
    scanDom().forEach((u) => map.set(u, u));
    try {
      const resp = await chrome.runtime.sendMessage({ type: "getVideos" });
      ((resp && resp.videos) || []).forEach((v) => {
        const url = typeof v === "string" ? v : v.url;
        if (url) map.set(url, url);
      });
    } catch (e) {}
    return [...map.keys()];
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

  function renderPanel() {
    ensureRoot();
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

  async function openPanel() {
    lastVideos = await collect();
    renderPanel();
  }

  // 右键菜单「嗅探本页视频」→ 打开面板
  if (TOP) {
    chrome.runtime.onMessage.addListener((msg) => {
      if (msg && msg.type === "showPanel") {
        openPanel();
      }
    });
  }
})();

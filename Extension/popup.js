// 速下扩展弹窗

const DEFAULTS = { mode: "auto" };

const statusEl = document.getElementById("status");
const toggleEl = document.getElementById("captureToggle");
const modeEl = document.getElementById("modeSelect");

function setStatus(connected, port) {
  if (connected) {
    statusEl.textContent = "已连接（端口 " + port + "）";
    statusEl.className = "status connected";
  } else {
    statusEl.textContent = "未连接：请先打开速下应用";
    statusEl.className = "status offline";
  }
}

async function refreshStatus() {
  const resp = await chrome.runtime.sendMessage({ type: "getStatus" });
  setStatus(resp && resp.connected, resp && resp.port);
}

document.addEventListener("DOMContentLoaded", async () => {
  const settings = await chrome.storage.sync.get(DEFAULTS);
  toggleEl.checked = settings.mode !== "off";
  modeEl.value = settings.mode || "auto";

  refreshStatus();

  toggleEl.addEventListener("change", () => {
    const mode = toggleEl.checked ? (modeEl.value === "off" ? "auto" : modeEl.value) : "off";
    modeEl.value = mode;
    chrome.storage.sync.set({ mode });
    if (mode === "off") {
      setStatus(false, null);
    } else {
      chrome.runtime.sendMessage({ type: "recheck" }, (resp) => {
        setStatus(resp && resp.connected, resp && resp.port);
      });
    }
  });

  modeEl.addEventListener("change", () => {
    chrome.storage.sync.set({ mode: modeEl.value });
    toggleEl.checked = modeEl.value !== "off";
  });
});

document.getElementById("openApp").addEventListener("click", async () => {
  const resp = await chrome.runtime.sendMessage({ type: "getStatus" });
  const port = (resp && resp.port) || 10007;
  // 唤起速下应用窗口
  await fetch("http://127.0.0.1:" + port + "/activate").catch(() => {});
  window.close();
});

document.getElementById("openOptions").addEventListener("click", () => {
  chrome.runtime.openOptionsPage();
});

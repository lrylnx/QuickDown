// 速下扩展弹窗
//
// 接管行为（弹不弹确认窗口、弹不弹主窗口）统一由速下 App 端设置决定；
// 扩展端只保留总开关（开启/关闭接管），避免两端各一套「接管方式」互相打架。

const DEFAULTS = { mode: "auto", sniff: true };

const statusEl = document.getElementById("status");
const toggleEl = document.getElementById("captureToggle");
const sniffEl = document.getElementById("sniffToggle");

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
  sniffEl.checked = settings.sniff !== false;

  refreshStatus();

  toggleEl.addEventListener("change", () => {
    const mode = toggleEl.checked ? "auto" : "off";
    chrome.storage.sync.set({ mode });
    if (mode === "off") {
      setStatus(false, null);
    } else {
      chrome.runtime.sendMessage({ type: "recheck" }, (resp) => {
        setStatus(resp && resp.connected, resp && resp.port);
      });
    }
  });

  // 视频嗅探快捷开关：与选项页共用同一个设置项
  sniffEl.addEventListener("change", () => {
    chrome.storage.sync.set({ sniff: sniffEl.checked });
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

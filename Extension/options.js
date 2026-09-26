// 速下扩展选项页
//
// 接管方式已移除（行为统一由速下 App 端设置决定，扩展只保留弹窗里的总开关）；
// 若 storage 里残留旧值 mode:"ask"，background.js 会按「自动接管」处理。

const DEFAULTS = { filter: "all", excluded: "", sniff: true };

document.addEventListener("DOMContentLoaded", async () => {
  const s = await chrome.storage.sync.get(DEFAULTS);

  document.querySelectorAll('input[name="filter"]').forEach((el) => {
    el.checked = el.value === s.filter;
  });
  document.getElementById("excluded").value = s.excluded || "";
  document.getElementById("sniff").checked = s.sniff !== false;

  document.getElementById("save").addEventListener("click", async () => {
    const filter = document.querySelector('input[name="filter"]:checked').value;
    const excluded = document.getElementById("excluded").value;
    const sniff = document.getElementById("sniff").checked;
    await chrome.storage.sync.set({ filter, excluded, sniff });
    const el = document.getElementById("saved");
    el.textContent = "已保存 ✓";
    setTimeout(() => (el.textContent = ""), 2000);
  });
});

// 速下扩展选项页

const DEFAULTS = { mode: "auto", filter: "all", excluded: "" };

document.addEventListener("DOMContentLoaded", async () => {
  const s = await chrome.storage.sync.get(DEFAULTS);

  document.querySelectorAll('input[name="mode"]').forEach((el) => {
    el.checked = el.value === s.mode;
  });
  document.querySelectorAll('input[name="filter"]').forEach((el) => {
    el.checked = el.value === s.filter;
  });
  document.getElementById("excluded").value = s.excluded || "";

  document.getElementById("save").addEventListener("click", async () => {
    const mode = document.querySelector('input[name="mode"]:checked').value;
    const filter = document.querySelector('input[name="filter"]:checked').value;
    const excluded = document.getElementById("excluded").value;
    await chrome.storage.sync.set({ mode, filter, excluded });
    const el = document.getElementById("saved");
    el.textContent = "已保存 ✓";
    setTimeout(() => (el.textContent = ""), 2000);
  });
});

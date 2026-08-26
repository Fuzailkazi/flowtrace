import { api, settings } from "./api.js";

const $ = (id) => document.getElementById(id);

(async () => {
  const current = await settings();
  $("port").value = current.port;
  $("token").value = current.token;
})();

$("save").addEventListener("click", async () => {
  const port = Number($("port").value) || 8787;
  const token = $("token").value.trim();
  await chrome.storage.local.set({ port, token });

  const status = $("status");
  status.hidden = false;
  try {
    await api.health();
    const { threads } = await api.threads();
    status.className = "status ok";
    status.textContent = `Connected. ${threads.length} open thread${threads.length === 1 ? "" : "s"}.`;
  } catch (error) {
    status.className = "status error";
    status.textContent = error.message;
  }
});

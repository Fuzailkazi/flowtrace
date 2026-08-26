import { api } from "./api.js";

const $ = (id) => document.getElementById(id);
const statusEl = $("status");

function show(message, kind = "error") {
  statusEl.textContent = message;
  statusEl.className = `status ${kind}`;
  statusEl.hidden = false;
}

async function currentTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function init() {
  const tab = await currentTab();
  $("tabinfo").textContent = tab?.url ?? "";

  try {
    const { threads } = await api.threads();
    const select = $("thread");
    select.innerHTML = "";
    for (const thread of threads) {
      const option = document.createElement("option");
      option.value = thread.id;
      option.textContent = thread.title;
      select.append(option);
    }
    const newOption = document.createElement("option");
    newOption.value = "";
    newOption.textContent = "New thread…";
    select.append(newOption);
    if (threads.length === 0) select.value = "";

    select.addEventListener("change", () => {
      $("newTitleField").hidden = select.value !== "";
    });
    $("newTitleField").hidden = select.value !== "";

    // If this URL is already filed, say so instead of silently duplicating it.
    if (tab?.url) {
      const { thread } = await api.threadForURL(tab.url);
      if (thread) {
        $("filed").textContent = `Already filed under "${thread.title}"`;
        $("filed").hidden = false;
        select.value = thread.id;
        $("newTitleField").hidden = true;
      }
    }
  } catch (error) {
    show(error.message);
    $("capture").disabled = true;
  }
}

$("capture").addEventListener("click", async () => {
  const button = $("capture");
  button.disabled = true;
  try {
    const scope = document.querySelector('input[name="scope"]:checked').value;
    const tabs =
      scope === "window"
        ? await chrome.tabs.query({ currentWindow: true })
        : [await currentTab()];

    const payload = {
      tabs: tabs
        .filter((tab) => tab.url?.startsWith("http"))
        .map((tab) => ({ title: tab.title, url: tab.url, browser: "Chrome" })),
      note: $("note").value,
      threadId: $("thread").value || undefined,
      newThreadTitle: $("thread").value ? undefined : $("newTitle").value,
    };
    if (payload.tabs.length === 0) throw new Error("No capturable tabs — internal pages are skipped.");

    const result = await api.captureTabs(payload);
    show(`Captured ${result.captured} tab${result.captured === 1 ? "" : "s"}.`, "ok");
    setTimeout(() => window.close(), 900);
  } catch (error) {
    show(error.message);
    button.disabled = false;
  }
});

$("openOptions").addEventListener("click", (event) => {
  event.preventDefault();
  chrome.runtime.openOptionsPage();
});

init();

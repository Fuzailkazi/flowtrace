// Keeps the toolbar badge showing whether the current tab is already filed
// under a work thread. This is the one thing AppleScript capture can't do:
// tell you, inside the browser, that you've already accounted for this tab.

const BADGE_FILED = "●";

async function refreshBadge(tabId, url) {
  if (!url || !url.startsWith("http")) {
    await chrome.action.setBadgeText({ tabId, text: "" });
    return;
  }
  try {
    const { port, token } = await chrome.storage.local.get({ port: 8787, token: "" });
    if (!token) return;

    const response = await fetch(
      `http://127.0.0.1:${port}/thread-for-url?url=${encodeURIComponent(url)}`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (!response.ok) return;

    const { thread } = await response.json();
    await chrome.action.setBadgeText({ tabId, text: thread ? BADGE_FILED : "" });
    await chrome.action.setBadgeBackgroundColor({ tabId, color: "#3b7dd8" });
    await chrome.action.setTitle({
      tabId,
      title: thread ? `Filed under "${thread.title}"` : "Capture to FlowTrace",
    });
  } catch {
    // The app simply isn't running. Leave the badge alone rather than nagging.
  }
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === "complete") refreshBadge(tabId, tab.url);
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  const tab = await chrome.tabs.get(tabId);
  refreshBadge(tabId, tab.url);
});

// Talks to the FlowTrace app on localhost. Nothing here reaches the network:
// the only host the extension may contact is 127.0.0.1, enforced by the
// manifest's host_permissions.

const DEFAULTS = { port: 8787, token: "" };

export async function settings() {
  const stored = await chrome.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...stored };
}

async function request(path, options = {}) {
  const { port, token } = await settings();
  if (!token) throw new Error("No token yet — open the extension options and paste it from FlowTrace → Settings.");

  let response;
  try {
    response = await fetch(`http://127.0.0.1:${port}${path}`, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        ...(options.headers || {}),
      },
    });
  } catch {
    throw new Error("FlowTrace isn't reachable. Is the app running with the extension endpoint switched on?");
  }

  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `FlowTrace returned ${response.status}`);
  return body;
}

export const api = {
  health: async () => {
    const { port } = await settings();
    const response = await fetch(`http://127.0.0.1:${port}/health`);
    return response.json();
  },
  threads: () => request("/threads"),
  threadForURL: (url) => request(`/thread-for-url?url=${encodeURIComponent(url)}`),
  captureTabs: (payload) =>
    request("/capture/tabs", { method: "POST", body: JSON.stringify(payload) }),
};

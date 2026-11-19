// Guests' comments waiting for approval, and reported ones
// (api/src/guests/). Its own file so the feature comes out cleanly: when
// guest accounts are off, /guests/queue is a 404 and the card stays hidden.
const card = document.getElementById("comments-card");
const list = document.getElementById("comments");
const badge = document.getElementById("comments-count");

const when = (ms) =>
  new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

function el(tag, props = {}, ...children) {
  const e = document.createElement(tag);
  Object.assign(e, props);
  e.append(...children);
  return e;
}

async function send(url, method, body) {
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    headers: body ? { "content-type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error ?? String(res.status));
}

async function act(fn, row) {
  row.querySelectorAll("button").forEach((b) => (b.disabled = true));
  try {
    await fn();
    await refresh();
  } catch (e) {
    alert(`Didn't work: ${e.message}`);
    row.querySelectorAll("button").forEach((b) => (b.disabled = false));
  }
}

function render(items) {
  card.hidden = false;
  badge.textContent = items.length ? `(${items.length})` : "";
  list.replaceChildren();
  if (!items.length) {
    list.append(el("li", { className: "small" }, "Nothing waiting."));
    return;
  }
  for (const c of items) {
    const row = el("li");
    const post = c.postType === "text" ? `on “${(c.postText ?? "").slice(0, 60)}”` : `on a ${c.postType} post`;
    const who = `${c.author.name ?? "(no name)"} · ${c.author.email}`;
    const what = el(
      "span",
      { className: "what" },
      el("strong", {}, c.text),
      el("br"),
      el("span", { className: "small" }, `${who} · ${post} · ${when(c.ts)}`),
    );
    if (c.author.link) what.append(el("br"), el("span", { className: "small" }, c.author.link));
    for (const r of c.reports) what.append(el("br"), el("span", { className: "small" }, `⚠️ Reported: ${r.reason}`));
    const approve = el("button", { textContent: c.status === "approved" ? "Keep" : "Approve" });
    approve.addEventListener("click", () =>
      act(() => send(`/guests/comments/${c.id}/decision`, "POST", { status: "approved" }), row),
    );
    const reject = el("button", { className: "secondary danger", textContent: c.status === "approved" ? "Remove" : "Reject" });
    reject.addEventListener("click", () =>
      act(() => send(`/guests/comments/${c.id}/decision`, "POST", { status: "rejected" }), row),
    );
    const ban = el("button", { className: "secondary danger", textContent: "Delete account" });
    ban.addEventListener("click", () => {
      if (!confirm(`Delete ${c.author.email}'s account, with all their comments and likes?`)) return;
      act(() => send(`/guests/accounts/${c.author.id}`, "DELETE"), row);
    });
    row.append(what, el("span", { className: "actions" }, approve, reject, ban));
    list.append(row);
  }
}

async function refresh() {
  try {
    const res = await fetch("/guests/queue", { credentials: "same-origin" });
    if (!res.ok) return; // 404: guests are off; 401: not signed in yet
    render((await res.json()).items);
  } catch {
    // Offline: try again on the next tick.
  }
}

refresh();
setInterval(refresh, 15_000);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") refresh();
});

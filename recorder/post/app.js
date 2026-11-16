// The upload page: Visit, Post and (later) Upload, from the road.
//
// Everything I do goes into an outbox on the phone (IndexedDB) first, with
// its own id and the time I did it, and is sent from there until the
// server confirms it. Bad signal only delays things; retries can't
// duplicate them (the server ignores an id it already has).
//
// Signs in with a passkey (Face ID), or the ingest token the first time.
// See recorder/DESIGN.md, "Posts".

const $ = (id) => document.getElementById(id);
const webauthn = window.SimpleWebAuthnBrowser;

// --- The outbox (IndexedDB) ---------------------------------------------

const DB_NAME = "mctrot-outbox";
const KEEP_SENT_MS = 7 * 86_400_000;

function openOutbox() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore("items", { keyPath: "id" });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

const dbReady = openOutbox();

async function tx(mode, fn) {
  const db = await dbReady;
  return new Promise((resolve, reject) => {
    const t = db.transaction("items", mode);
    const result = fn(t.objectStore("items"));
    t.oncomplete = () => resolve(result?.result ?? result);
    t.onerror = () => reject(t.error);
  });
}

const putItem = (item) => tx("readwrite", (s) => s.put(item));
const deleteItem = (id) => tx("readwrite", (s) => s.delete(id));
const allItems = async () => {
  const items = await tx("readonly", (s) => s.getAll());
  return items.sort((a, b) => b.createdAt - a.createdAt);
};

// An item: { id, kind: "visit" | "post", ts, text?, state, error?, createdAt, sentAt? }
// state: "queued" (waiting for signal or its turn), "sending", "sent", "failed".
async function enqueue(kind, fields = {}) {
  const now = Date.now();
  const item = { id: crypto.randomUUID(), kind, ts: now, ...fields, state: "queued", createdAt: now };
  await putItem(item);
  await render();
  flush();
  return item;
}

// --- Sending ---------------------------------------------------------------

let online = null; // null until the first request: unknown
let needsSignIn = false;
let flushing = false;

function request(item) {
  if (item.kind === "visit") return { url: "/visits", body: { id: item.id, ts: item.ts } };
  return { url: "/posts", body: { id: item.id, ts: item.ts, type: "text", text: item.text } };
}

async function api(url, body) {
  return fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify(body ?? {}),
  });
}

// Sends queued items oldest first; stops at the first one that can't go
// now (no signal, signed out), so order is kept and nothing is skipped.
async function flush() {
  if (flushing || needsSignIn) return;
  flushing = true;
  try {
    const queued = (await allItems()).filter((i) => i.state === "queued").reverse();
    for (const item of queued) {
      item.state = "sending";
      await putItem(item);
      await render();
      let res;
      try {
        const { url, body } = request(item);
        res = await api(url, body);
      } catch {
        // No signal. Try again later.
        item.state = "queued";
        await putItem(item);
        setOnline(false);
        break;
      }
      setOnline(true);
      if (res.ok) {
        item.state = "sent";
        item.sentAt = Date.now();
        delete item.error;
      } else if (res.status === 401) {
        item.state = "queued";
        needsSignIn = true;
      } else if (res.status >= 500) {
        item.state = "queued";
        item.error = `Server error ${res.status}; will retry`;
      } else {
        item.state = "failed";
        item.error = (await res.json().catch(() => ({}))).error ?? `Rejected (${res.status})`;
      }
      await putItem(item);
      if (item.state === "queued") break;
    }
  } finally {
    flushing = false;
    await render();
    if (needsSignIn) showSignIn("Signed out; sign in again. Nothing in the outbox is lost.");
  }
}

function setOnline(value) {
  online = value;
  $("net").className = "dot " + (value ? "online" : "offline");
  $("net").title = value ? "Reached the server" : "Can’t reach the server";
}

// Retry on every chance: coming back online, reopening the page, a timer.
addEventListener("online", () => flush());
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") flush();
});
setInterval(() => flush(), 10_000);

// --- Rendering ---------------------------------------------------------------

const STATE_TEXT = {
  queued: "Waiting for signal",
  sending: "Sending…",
  sent: "Sent ✓",
  failed: "Failed",
};

function timeText(ms) {
  return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

async function render() {
  const now = Date.now();
  const items = await allItems();
  // Forget sent items after a week.
  for (const i of items) if (i.state === "sent" && now - i.sentAt > KEEP_SENT_MS) await deleteItem(i.id);
  const visible = items.filter((i) => !(i.state === "sent" && now - i.sentAt > KEEP_SENT_MS));

  const list = $("outbox");
  list.replaceChildren(
    ...visible.slice(0, 50).map((item) => {
      const li = document.createElement("li");
      const what = document.createElement("span");
      what.className = "what";
      what.textContent = item.kind === "visit" ? "📍 Visit" : `💬 ${item.text}`;
      const when = document.createElement("span");
      when.className = "when";
      when.textContent = timeText(item.ts);
      const state = document.createElement("span");
      state.className = `state ${item.state}`;
      state.textContent = item.state === "queued" && item.error ? item.error : STATE_TEXT[item.state];
      li.append(what, when, state);
      if (item.state === "failed") {
        const actions = document.createElement("span");
        actions.className = "actions";
        const reason = document.createElement("div");
        reason.className = "small";
        reason.textContent = item.error ?? "";
        const retry = button("Retry", async () => {
          item.state = "queued";
          delete item.error;
          await putItem(item);
          flush();
        });
        const discard = button("Discard", async () => {
          if (confirm("Discard this for good? It hasn’t reached the server.")) {
            await deleteItem(item.id);
            render();
          }
        });
        actions.append(retry, discard);
        what.append(reason);
        li.append(actions);
      }
      return li;
    }),
  );
  $("empty").hidden = visible.length > 0;

  const pending = items.filter((i) => i.state === "queued" || i.state === "sending").length;
  const failed = items.filter((i) => i.state === "failed").length;
  const parts = [];
  if (pending) parts.push(`${pending} waiting`);
  if (failed) parts.push(`${failed} failed`);
  $("summary").textContent = parts.length ? parts.join(" · ") : online === false ? "Offline" : "All sent";
  // The home-screen icon's badge counts what hasn't reached the server.
  if ("setAppBadge" in navigator) {
    (pending + failed ? navigator.setAppBadge(pending + failed) : navigator.clearAppBadge()).catch(() => {});
  }
}

function button(label, onClick) {
  const b = document.createElement("button");
  b.className = "secondary";
  b.textContent = label;
  b.addEventListener("click", onClick);
  return b;
}

let flashTimer;
function flash(text) {
  $("flash").textContent = text;
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => ($("flash").textContent = ""), 2500);
}

// --- Buttons -------------------------------------------------------------

$("visit").addEventListener("click", async () => {
  await enqueue("visit");
  flash("Visit saved");
});

$("post").addEventListener("click", () => {
  $("composer").hidden = false;
  $("text").focus();
});

$("text").addEventListener("input", () => {
  $("count").textContent = `${$("text").value.length} / 1000`;
});

$("cancel").addEventListener("click", () => {
  $("composer").hidden = true;
});

$("send").addEventListener("click", async () => {
  const text = $("text").value.trim();
  if (!text) return;
  // The time is when I hit Post, not when it reaches the server.
  await enqueue("post", { text });
  $("text").value = "";
  $("count").textContent = "0 / 1000";
  $("composer").hidden = true;
  flash("Post saved");
});

// --- Signing in ------------------------------------------------------------

function showSignIn(message = "") {
  $("signin").hidden = false;
  $("app").hidden = false; // the outbox stays visible: nothing is lost
  $("signin-error").textContent = message;
}

function signedIn() {
  needsSignIn = false;
  $("signin").hidden = true;
  $("app").hidden = false;
  flush();
}

async function checkSession() {
  try {
    const me = await (await fetch("/auth/me", { credentials: "same-origin" })).json();
    setOnline(true);
    $("faceid").hidden = me.passkeys === 0;
    $("token-box").open = me.passkeys === 0;
    $("add-passkey").textContent = me.passkeys === 0 ? "Add Face ID to this phone" : "Add Face ID to another device";
    if (me.signedIn) signedIn();
    else showSignIn(me.canSignIn ? "" : "Sign-in isn’t set up on the server (no session secret).");
  } catch {
    // Offline at startup: show the outbox; it sends once we're back.
    setOnline(false);
    $("app").hidden = false;
  }
}

$("token-go").addEventListener("click", async () => {
  const res = await api("/auth/token", { token: $("token").value }).catch(() => null);
  if (res?.ok) {
    $("token").value = "";
    signedIn();
    flash("Signed in. Add Face ID below for next time.");
  } else {
    $("signin-error").textContent = res ? "That’s not the token." : "Can’t reach the server.";
  }
});

$("faceid").addEventListener("click", async () => {
  try {
    const { flowId, options } = await (await api("/auth/login/options")).json();
    const response = await webauthn.startAuthentication({ optionsJSON: options });
    const res = await api("/auth/login/verify", { flowId, response });
    if (!res.ok) throw new Error((await res.json()).error);
    signedIn();
  } catch (err) {
    $("signin-error").textContent = `Face ID didn’t work: ${err.message ?? err}`;
  }
});

$("add-passkey").addEventListener("click", async (event) => {
  event.preventDefault();
  try {
    const optionsRes = await api("/auth/register/options");
    if (!optionsRes.ok) throw new Error("sign in first");
    const { flowId, options } = await optionsRes.json();
    const response = await webauthn.startRegistration({ optionsJSON: options });
    const res = await api("/auth/register/verify", { flowId, response });
    if (!res.ok) throw new Error((await res.json()).error);
    flash("Face ID added. Next time, just tap Sign in with Face ID.");
    checkSession();
  } catch (err) {
    flash(`Couldn’t add Face ID: ${err.message ?? err}`);
  }
});

$("signout").addEventListener("click", async (event) => {
  event.preventDefault();
  await api("/auth/signout").catch(() => {});
  showSignIn();
});

render();
checkSession();

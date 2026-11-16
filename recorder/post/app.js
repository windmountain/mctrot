// The upload page: Check In, Post and Upload, from the road, and a list of
// what's been sent, where anything can be deleted and text posts edited.
//
// Everything I do goes into an outbox on the phone (IndexedDB) first, with
// its own id and the time I did it, and is sent from there until the
// server confirms it. Bad signal only delays things; retries can't
// duplicate them (the server ignores an id it already has).
//
// Two lanes, so a long video upload never holds up a check-in: messages
// (check-ins, text posts) and uploads (photos, videos, voice notes) send
// independently. Uploads use tus, so a dropped upload resumes where it
// stopped, even after the page is closed and reopened.
//
// Signs in with a passkey (Face ID), or the ingest token the first time.
// See recorder/DESIGN.md, "Posts".

const $ = (id) => document.getElementById(id);
const webauthn = window.SimpleWebAuthnBrowser;

const MAX_UPLOAD_BYTES = 1024 ** 3; // as the server (api/src/uploads.ts)
const UPLOAD_CHUNK = 5 * 1024 * 1024;

// --- The outbox (IndexedDB) ---------------------------------------------

const DB_NAME = "mctrot-outbox";

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

// An item: { id, kind: "visit" (a check-in) | "post" | "upload", ts, state, error?,
//   createdAt, sentAt?, text? (post), file?, name?, type?, size?, media? (upload) }
// state: "queued" (waiting for signal or its turn), "sending" or
// "uploading", "processing" (uploaded; the server is working on it),
// "sent" (then it leaves the outbox for the Sent list), "failed".
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

function setOnline(value) {
  online = value;
  $("net").className = "dot " + (value ? "online" : "offline");
  $("net").title = value ? "Reached the server" : "Can’t reach the server";
}

async function api(url, body, method = "POST") {
  return fetch(url, {
    method,
    headers: { "content-type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify(body ?? {}),
  });
}

function flush() {
  flushMessages();
  flushUploads();
  pollProcessing();
}

// Each lane sends its queued items oldest first and stops at the first
// that can't go now (no signal, signed out), so nothing is skipped.
function lane(isMine, send) {
  let busy = false;
  return async function run() {
    if (busy || needsSignIn) return;
    busy = true;
    try {
      const queued = (await allItems()).filter((i) => i.state === "queued" && isMine(i)).reverse();
      for (const item of queued) {
        const outcome = await send(item);
        if (outcome !== "next") break;
      }
    } finally {
      busy = false;
      await render();
      if (needsSignIn) showSignIn("Signed out; sign in again. Nothing in the outbox is lost.");
    }
  };
}

// Records how a send went; says whether the lane may carry on.
async function settle(item, result) {
  if (result.ok) {
    setOnline(true);
    Object.assign(item, result.ok);
    delete item.error;
  } else if (result.offline) {
    setOnline(false);
    item.state = "queued";
  } else if (result.signIn) {
    setOnline(true);
    item.state = "queued";
    needsSignIn = true;
  } else if (result.retryLater) {
    setOnline(true);
    item.state = "queued";
    item.error = result.retryLater;
  } else {
    setOnline(true);
    item.state = "failed";
    item.error = result.failed;
  }
  await putItem(item);
  return item.state === "queued" ? "stop" : "next";
}

const flushMessages = lane(
  (i) => i.kind !== "upload",
  async (item) => {
    item.state = "sending";
    await putItem(item);
    await render();
    const body =
      item.kind === "visit"
        ? { url: "/visits", json: { id: item.id, ts: item.ts } }
        : { url: "/posts", json: { id: item.id, ts: item.ts, type: "text", text: item.text } };
    let res;
    try {
      res = await api(body.url, body.json);
    } catch {
      return settle(item, { offline: true });
    }
    if (res.ok) return settle(item, { ok: { state: "sent", sentAt: Date.now() } });
    if (res.status === 401) return settle(item, { signIn: true });
    if (res.status >= 500) return settle(item, { retryLater: `Server error ${res.status}; will retry` });
    return settle(item, { failed: (await res.json().catch(() => ({}))).error ?? `Rejected (${res.status})` });
  },
);

// Upload progress lives in memory (writing IndexedDB on every event would
// be slow); a reopened page starts from what tus says the server has.
const progress = new Map();

const flushUploads = lane(
  (i) => i.kind === "upload",
  async (item) => {
    item.state = "uploading";
    await putItem(item);
    await render();
    const result = await uploadFile(item);
    progress.delete(item.id);
    if (result.ok) {
      // Uploaded; the server processes it next (see pollProcessing).
      return settle(item, { ok: { state: "processing", uploadedAt: Date.now() } });
    }
    return settle(item, result);
  },
);

function uploadFile(item) {
  return new Promise((resolve) => {
    const upload = new window.tus.Upload(item.file, {
      endpoint: "/uploads",
      chunkSize: UPLOAD_CHUNK,
      retryDelays: [0, 1000, 3000, 6000],
      metadata: { postId: item.id, ts: String(item.ts), filetype: item.type, filename: item.name },
      // Resume by the outbox id, even after the page is closed.
      fingerprint: async () => `mctrot-upload-${item.id}`,
      removeFingerprintOnSuccess: true,
      onProgress(sent, total) {
        progress.set(item.id, { sent, total });
        scheduleRender();
      },
      onSuccess: () => resolve({ ok: true }),
      onError(err) {
        const res = err.originalResponse;
        const status = res?.getStatus?.() ?? 0;
        if (status === 401) resolve({ signIn: true });
        else if (status >= 400 && status < 500) resolve({ failed: res.getBody() || `Rejected (${status})` });
        else if (status >= 500) resolve({ retryLater: `Server error ${status}; will retry` });
        else resolve({ offline: true });
      },
    });
    upload
      .findPreviousUploads()
      .then((previous) => {
        if (previous.length) upload.resumeFromPreviousUpload(previous[0]);
        upload.start();
      })
      .catch(() => upload.start());
  });
}

// Uploaded items wait for the server's worker; ask how they're doing.
let polling = false;
async function pollProcessing() {
  if (polling) return;
  const waiting = (await allItems()).filter((i) => i.state === "processing");
  if (!waiting.length) return;
  polling = true;
  try {
    const ids = waiting.map((i) => i.id).join(",");
    const res = await fetch(`/posts/status?ids=${encodeURIComponent(ids)}`, { credentials: "same-origin" });
    if (res.status === 401) {
      needsSignIn = true;
      return;
    }
    if (!res.ok) return;
    const statuses = await res.json();
    for (const item of waiting) {
      const s = statuses[item.id];
      if (s?.status === "ready") {
        item.state = "sent";
        item.sentAt = Date.now();
        delete item.file; // free the phone's storage
        await putItem(item);
      } else if (s?.status === "failed") {
        item.state = "failed";
        item.error = s.error ?? "Processing failed";
        item.processingFailed = true;
        await putItem(item);
      }
    }
  } catch {
    // No signal; try again later.
  } finally {
    polling = false;
    render();
  }
}

// Retry on every chance: coming back online, reopening the page, a timer.
addEventListener("online", () => flush());
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    flush();
    refreshSent();
  }
});
setInterval(() => flush(), 5_000);

// --- Rendering ---------------------------------------------------------------

const STATE_TEXT = {
  queued: "Waiting for signal",
  sending: "Sending…",
  uploading: "Uploading…",
  processing: "Processing on server",
  sent: "Sent ✓",
  failed: "Failed",
};

const MEDIA_ICON = { photo: "📷", video: "🎬", voice: "🎙️" };

function timeText(ms) {
  return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

// Today: just the time; earlier: the date too.
function dateTimeText(ms) {
  const d = new Date(ms);
  if (d.toDateString() === new Date().toDateString()) return timeText(ms);
  return d.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

const mb = (bytes) => (bytes / 1024 / 1024).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0);

// A local preview of a photo, from the file in the outbox.
const previews = new Map();
function previewUrl(item) {
  if (!previews.has(item.id)) previews.set(item.id, URL.createObjectURL(item.file));
  return previews.get(item.id);
}

let renderTimer;
function scheduleRender() {
  if (!renderTimer) renderTimer = setTimeout(() => ((renderTimer = null), render()), 300);
}

function stateText(item) {
  if (item.state === "uploading") {
    const p = progress.get(item.id);
    if (p && p.total) {
      return `Uploading ${Math.floor((p.sent / p.total) * 100)}% · ${mb(p.sent)} of ${mb(p.total)} MB`;
    }
  }
  if (item.state === "queued" && item.error) return item.error;
  return STATE_TEXT[item.state];
}

function thumb(item) {
  if (item.kind !== "upload") return null;
  if (item.media === "photo" && item.file) {
    const img = document.createElement("img");
    img.className = "thumb";
    img.alt = "";
    img.src = previewUrl(item);
    return img;
  }
  const span = document.createElement("span");
  span.className = "thumb icon";
  span.textContent = MEDIA_ICON[item.media] ?? "📎";
  return span;
}

async function render() {
  let items = await allItems();
  // Sent items are on the server now: they move to the Sent list.
  const justSent = items.filter((i) => i.state === "sent");
  if (justSent.length) {
    for (const i of justSent) {
      await deleteItem(i.id);
      URL.revokeObjectURL(previews.get(i.id));
      previews.delete(i.id);
    }
    items = items.filter((i) => i.state !== "sent");
    refreshSent();
  }
  outboxIds = new Set(items.map((i) => i.id));
  const visible = items;

  const list = $("outbox");
  list.replaceChildren(
    ...visible.slice(0, 50).map((item) => {
      const li = document.createElement("li");
      const t = thumb(item);
      if (t) li.append(t);
      const what = document.createElement("span");
      what.className = "what";
      what.textContent =
        item.kind === "visit"
          ? "📍 Check-in"
          : item.kind === "post"
            ? `💬 ${item.text}`
            : `${item.name} · ${mb(item.size)} MB`;
      if (item.state === "uploading") {
        const p = progress.get(item.id);
        const bar = document.createElement("div");
        bar.className = "progress";
        const fill = document.createElement("div");
        fill.style.width = `${p && p.total ? (p.sent / p.total) * 100 : 0}%`;
        bar.append(fill);
        what.append(bar);
      }
      const when = document.createElement("span");
      when.className = "when";
      when.textContent = timeText(item.ts);
      const state = document.createElement("span");
      state.className = `state ${item.state}`;
      state.textContent = stateText(item);
      li.append(what, when, state);
      // Not yet on the server: discard it here. Processing: it is on the
      // server, so delete it there.
      if (item.state === "queued") {
        li.append(
          actions(
            button("Discard", async () => {
              if (confirm("Discard this? It hasn’t reached the server.")) {
                await deleteItem(item.id);
                render();
              }
            }),
          ),
        );
      } else if (item.state === "processing") {
        li.append(
          actions(
            button("Delete", async () => {
              if (await deleteOnServer({ kind: "post", id: item.id })) {
                await deleteItem(item.id);
                render();
              }
            }, "danger"),
          ),
        );
      }
      if (item.state === "failed") {
        const actions = document.createElement("span");
        actions.className = "actions";
        const reason = document.createElement("div");
        reason.className = "small";
        reason.textContent = item.error ?? "";
        what.append(reason);
        // A file the server couldn't process won't do better a second time.
        if (!item.processingFailed) {
          actions.append(
            button("Retry", async () => {
              item.state = "queued";
              delete item.error;
              await putItem(item);
              flush();
            }),
          );
        }
        actions.append(
          button("Discard", async () => {
            if (confirm("Discard this for good? It hasn’t reached the server.")) {
              await deleteItem(item.id);
              render();
            }
          }),
        );
        li.append(actions);
      }
      return li;
    }),
  );
  $("outbox-card").hidden = visible.length === 0;
  renderSent();

  const count = (states) => items.filter((i) => states.includes(i.state)).length;
  const parts = [];
  const uploading = count(["uploading"]);
  const waiting = count(["queued", "sending"]);
  const processing = count(["processing"]);
  const failed = count(["failed"]);
  if (uploading) parts.push(`${uploading} uploading`);
  if (waiting) parts.push(`${waiting} waiting`);
  if (processing) parts.push(`${processing} processing`);
  if (failed) parts.push(`${failed} failed`);
  $("summary").textContent = parts.length ? parts.join(" · ") : online === false ? "Offline" : "All sent";
  // The home-screen icon's badge counts what hasn't reached the server.
  const pending = uploading + waiting + failed;
  if ("setAppBadge" in navigator) {
    (pending ? navigator.setAppBadge(pending) : navigator.clearAppBadge()).catch(() => {});
  }
}

function actions(...buttons) {
  const span = document.createElement("span");
  span.className = "actions";
  span.append(...buttons);
  return span;
}

function button(label, onClick, extraClass = "") {
  const b = document.createElement("button");
  b.className = `secondary ${extraClass}`.trim();
  b.textContent = label;
  b.addEventListener("click", onClick);
  return b;
}

let flashTimer;
function flash(text) {
  $("flash").textContent = text;
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => ($("flash").textContent = ""), 3000);
}

// --- Sent: what the server has ---------------------------------------------

// From GET /sent; null until first loaded.
let sent = null;
let sentStale = false;
let outboxIds = new Set();
let editing = null; // the text post being edited, if any

async function refreshSent() {
  if (needsSignIn) return;
  try {
    const res = await fetch("/sent", { credentials: "same-origin" });
    if (res.status === 401) {
      needsSignIn = true;
      return;
    }
    if (!res.ok) throw new Error(String(res.status));
    sent = (await res.json()).items;
    sentStale = false;
    setOnline(true);
  } catch {
    sentStale = true;
  }
  renderSent();
}

const MEDIA_NAME = { photo: "Photo", video: "Video", voice: "Voice note" };

function sentWhat(item) {
  if (item.kind === "checkin") return "📍 Check-in";
  if (item.type === "text") return `💬 ${item.text}`;
  return `${MEDIA_ICON[item.type]} ${MEDIA_NAME[item.type]}`;
}

function renderSent() {
  const list = $("sent");
  // Something still in the outbox (being processed) is shown there.
  const rows = (sent ?? []).filter((i) => !outboxIds.has(i.id));
  list.replaceChildren(
    ...rows.map((item) => {
      const li = document.createElement("li");
      if (editing?.id === item.id) li.className = "editing";
      if (item.thumbUrl) {
        const img = document.createElement("img");
        img.className = "thumb";
        img.alt = "";
        img.loading = "lazy";
        img.src = item.thumbUrl;
        li.append(img);
      }
      const what = document.createElement("span");
      what.className = "what";
      what.textContent = sentWhat(item);
      if (item.kind === "post" && item.status !== "ready") {
        const note = document.createElement("div");
        note.className = "small";
        note.textContent = item.status === "failed" ? `Failed: ${item.error ?? "processing failed"}` : "Processing on server";
        what.append(note);
      }
      const when = document.createElement("span");
      when.className = "when";
      when.textContent = dateTimeText(item.ts);
      const buttons = [];
      if (item.kind === "post" && item.type === "text") buttons.push(button("Edit", () => startEditing(item)));
      buttons.push(
        button("Delete", async () => {
          if (await deleteOnServer(item)) {
            sent = sent.filter((i) => i.id !== item.id);
            renderSent();
          }
        }, "danger"),
      );
      li.append(what, when, actions(...buttons));
      return li;
    }),
  );
  $("sent-empty").hidden = sent === null || rows.length > 0;
  $("sent-note").hidden = !(sentStale || sent === null);
  $("sent-note").textContent =
    sent === null ? (sentStale ? "Can’t load the sent list without signal." : "Loading…") : "Offline: this list may be out of date.";
}

// Deleting is for good. Returns whether it's gone.
async function deleteOnServer(item) {
  const what = item.kind === "checkin" || item.kind === "visit" ? "this check-in" : "this post";
  if (!confirm(`Delete ${what} for good? It disappears from /live.`)) return false;
  const url = item.kind === "checkin" ? `/visits/${encodeURIComponent(item.id)}` : `/posts/${encodeURIComponent(item.id)}`;
  let res;
  try {
    res = await api(url, undefined, "DELETE");
  } catch {
    flash("Can’t delete without signal. Try again when you have some.");
    return false;
  }
  if (res.status === 401) {
    showSignIn("Sign in again to delete.");
    return false;
  }
  // Already gone counts as deleted.
  if (!res.ok && res.status !== 404) {
    flash(`Couldn’t delete: ${(await res.json().catch(() => ({}))).error ?? res.status}`);
    return false;
  }
  flash("Deleted");
  return true;
}

function startEditing(item) {
  editing = item;
  $("text").value = item.text;
  $("count").textContent = `${item.text.length} / 1000`;
  $("send").textContent = "Save";
  $("composer").hidden = false;
  $("text").focus();
  renderSent();
}

function stopEditing() {
  editing = null;
  $("text").value = "";
  $("count").textContent = "0 / 1000";
  $("send").textContent = "Post";
  $("composer").hidden = true;
  renderSent();
}

// Edits go straight to the server (not the outbox): they need signal.
async function saveEdit(text) {
  let res;
  try {
    res = await api(`/posts/${encodeURIComponent(editing.id)}`, { text }, "PATCH");
  } catch {
    flash("Can’t save the edit without signal. Try again when you have some.");
    return;
  }
  if (res.status === 401) {
    showSignIn("Sign in again to save the edit.");
    return;
  }
  if (!res.ok) {
    flash(`Couldn’t save: ${(await res.json().catch(() => ({}))).error ?? res.status}`);
    return;
  }
  const saved = (await res.json()).text;
  sent = sent.map((i) => (i.id === editing.id ? { ...i, text: saved } : i));
  stopEditing();
  flash("Edit saved");
}

// --- Buttons -------------------------------------------------------------

$("visit").addEventListener("click", async () => {
  await enqueue("visit");
  flash("Checked in");
});

$("post").addEventListener("click", () => {
  if (editing) stopEditing();
  $("composer").hidden = false;
  $("text").focus();
});

$("text").addEventListener("input", () => {
  $("count").textContent = `${$("text").value.length} / 1000`;
});

$("cancel").addEventListener("click", () => {
  if (editing) stopEditing();
  else $("composer").hidden = true;
});

$("send").addEventListener("click", async () => {
  const text = $("text").value.trim();
  if (!text) return;
  if (editing) return saveEdit(text);
  // The time is when I hit Post, not when it reaches the server.
  await enqueue("post", { text });
  $("text").value = "";
  $("count").textContent = "0 / 1000";
  $("composer").hidden = true;
  flash("Post saved");
});

$("upload").addEventListener("click", () => $("file").click());

function mediaOf(type) {
  if (type.startsWith("image/")) return "photo";
  if (type.startsWith("video/")) return "video";
  if (type.startsWith("audio/")) return "voice";
  return null;
}

$("file").addEventListener("change", async () => {
  const file = $("file").files[0];
  $("file").value = "";
  if (!file) return;
  // Caught here, before anything is queued.
  const media = mediaOf(file.type);
  if (!media) {
    flash(`Can’t post that kind of file (${file.type || file.name}).`);
    return;
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    flash(`Too big: ${mb(file.size)} MB (the limit is ${mb(MAX_UPLOAD_BYTES)} MB). Try a shorter clip.`);
    return;
  }
  // When it was made: a photo just taken is "now"; one picked from the
  // library keeps its own time, if the phone gives it.
  const ts = file.lastModified && file.lastModified < Date.now() ? file.lastModified : Date.now();
  await enqueue("upload", { ts, file, name: file.name, type: file.type, size: file.size, media });
  flash(`${media === "photo" ? "Photo" : media === "video" ? "Video" : "Voice note"} saved`);
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
  refreshSent();
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

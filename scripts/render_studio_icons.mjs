// Renders a set of icons with website/preview-studio.html (the favicon and
// share-image studio), in headless Chrome: sets its text, clicks each
// download button, and saves what it would have downloaded.
//
//   node scripts/render_studio_icons.mjs OUT_DIR [TEXT] [SMALL_TEXT]
//
// TEXT may hold "\n" for a second line; SMALL_TEXT is what the 48 px and
// smaller icons show (default: the first letter). With neither, it renders
// the site's own icons. The upload page's (recorder/post/icons/):
//
//   node scripts/render_studio_icons.mjs recorder/post/icons 'McTrot\nCTRL' C
//
// Set CHROME to the browser binary if it isn't at the macOS default.

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [outArg, textArg, smallArg] = process.argv.slice(2);
if (!outArg) {
  console.error("usage: node scripts/render_studio_icons.mjs OUT_DIR [TEXT] [SMALL_TEXT]");
  process.exit(2);
}
const out = resolve(outArg);
const text = (textArg ?? "McTrot").replace(/\\n/g, "\n");
const small = smallArg ?? "";
const studio = pathToFileURL(join(dirname(fileURLToPath(import.meta.url)), "..", "website", "preview-studio.html")).href;
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const profile = mkdtempSync(join(tmpdir(), "mctrot-chrome-"));
const browser = spawn(chrome, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const wsUrl = await new Promise((resolve, reject) => {
  let err = "";
  browser.stderr.on("data", (d) => {
    err += d;
    const m = err.match(/DevTools listening on (ws:\S+)/);
    if (m) resolve(m[1]);
  });
  browser.on("exit", () => reject(new Error("Chrome exited:\n" + err)));
});

const control = await connect(wsUrl);
const { targetId } = await control.send("Target.createTarget", { url: "about:blank" });
control.close();
const tab = await connect(wsUrl.replace(/browser\/.*/, "page/" + targetId));

const js = async (expression) =>
  (await tab.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;

try {
  await tab.send("Page.navigate", { url: studio });
  await sleep(1000);
  // Capture downloads instead of saving them: the studio downloads through
  // a temporary <a download> it clicks.
  await js(`
    window.__files = {};
    HTMLAnchorElement.prototype.click = function () {
      const name = this.download, href = this.href;
      window.__files[name] = fetch(href).then(r => r.arrayBuffer()).then(b => {
        let s = ""; for (const x of new Uint8Array(b)) s += String.fromCharCode(x);
        return btoa(s);
      });
    };
    const set = (id, value) => { const el = document.getElementById(id); el.value = value; el.dispatchEvent(new Event("input")); };
    set("text", ${JSON.stringify(text)});
    set("smallText", ${JSON.stringify(small)});
    true`);
  await sleep(300);
  // Every icon card's button, the .ico and the .svg (not adaptive: the site's
  // favicon.svg is a single light mark), then wait for the PNG blobs.
  await js(`
    document.getElementById("svgAdaptive").checked = false;
    for (const b of document.querySelectorAll(".card .btn-row button")) {
      if (/^(Download|Build)/.test(b.textContent)) b.click();
    }
    true`);
  await sleep(1500);
  const names = await js(`Object.keys(window.__files)`);
  mkdirSync(out, { recursive: true });
  for (const name of names) {
    if (name === "og-image.png") continue; // the share image isn't an icon
    const data = await js(`window.__files[${JSON.stringify(name)}]`);
    writeFileSync(join(out, name), Buffer.from(data, "base64"));
    console.log(`${outArg}/${name}`);
  }
} finally {
  tab.close();
  const exited = new Promise((r) => browser.once("exit", r));
  browser.kill();
  await exited;
  rmSync(profile, { recursive: true, force: true });
}

async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (!pending.has(d.id)) return;
    const { resolve, reject } = pending.get(d.id);
    pending.delete(d.id);
    d.error ? reject(new Error(d.error.message)) : resolve(d.result);
  };
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      pending.set(++id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  return { send, close: () => ws.close() };
}

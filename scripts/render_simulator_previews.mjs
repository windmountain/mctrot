// Renders the simulator's share image and icons in website/sim/ from their
// hand-editable SVG sources, with headless Chrome:
//
//   og.svg       -> og.png (1200x630, the og:image; social sites need a PNG)
//   icon.svg     -> icon-512.png, icon-192.png, apple-touch-icon.png
//   favicon.svg  -> favicon-32.png
//
// Usage: node scripts/render_simulator_previews.mjs, then website/build.sh.
// Set CHROME to the browser binary if it isn't at the macOS default.

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const sim = join(dirname(fileURLToPath(import.meta.url)), "..", "website", "sim");
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const renders = [
  ["og.svg", 1200, 630, "og.png"],
  ["icon.svg", 512, 512, "icon-512.png"],
  ["icon.svg", 192, 192, "icon-192.png"],
  ["icon.svg", 180, 180, "apple-touch-icon.png"],
  ["favicon.svg", 32, 32, "favicon-32.png"],
];

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

try {
  for (const [src, width, height, name] of renders) {
    const svg = readFileSync(join(sim, src)).toString("base64");
    const html = `<!DOCTYPE html><style>html,body{margin:0;background:transparent}img{display:block}</style><img src="data:image/svg+xml;base64,${svg}" width="${width}" height="${height}">`;
    await tab.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
    await tab.send("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
    await tab.send("Page.navigate", { url: "data:text/html;base64," + Buffer.from(html).toString("base64") });
    await sleep(800);
    const { data } = await tab.send("Page.captureScreenshot", { format: "png" });
    writeFileSync(join(sim, name), Buffer.from(data, "base64"));
    console.log(`website/sim/${src} -> ${name}`);
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

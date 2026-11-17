// Serves website/build/ locally the way Netlify serves it, for previewing:
// "/live" finds live.html (Netlify's pretty URLs), and website/_redirects'
// rewrites apply, so /live/map and the other /live views work. No
// dependencies.
//
//   preview-website [port]   # devenv: build, serve, rebuild on save
//   serve-website [port]     # devenv: just serve build/ as it is
//   node scripts/serve_site.mjs [port]   # the same, directly
//
// The page talks to the real recorder (api.mctrot.nyc) unless you add
// ?api=http://localhost:3000 to point it at a local one.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../website/build/", import.meta.url));
const port = Number(process.argv[2] ?? 8000);

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml",
};

// website/_redirects' rewrites (status 200): "/live/*  /live.html  200".
const rewrites = (await readFile(join(root, "_redirects"), "utf8").catch(() => ""))
  .split("\n")
  .map((line) => line.trim().split(/\s+/))
  .filter(([from, , status]) => from && !from.startsWith("#") && status === "200")
  .map(([from, to]) => ({
    test: new RegExp(`^${from.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`),
    to,
  }));

async function isFile(path) {
  return stat(path).then((s) => s.isFile(), () => false);
}

// A request path to a file in build/, as Netlify would find it.
async function resolve(pathname) {
  const path = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, "");
  for (const candidate of [path, `${path}.html`, join(path, "index.html")]) {
    if (await isFile(join(root, candidate))) return candidate;
  }
  const rewrite = rewrites.find((r) => r.test.test(path));
  return rewrite ? rewrite.to : null;
}

createServer(async (req, res) => {
  const file = await resolve(new URL(req.url, "http://localhost").pathname);
  if (!file) {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("Not found");
    return;
  }
  res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
  res.end(await readFile(join(root, file)));
})
  .on("error", (err) => {
    console.error(
      err.code === "EADDRINUSE"
        ? `Port ${port} is already in use (another server? \`lsof -nP -iTCP:${port} -sTCP:LISTEN\` shows which). Try another port: preview-website ${port + 1}`
        : err.message,
    );
    process.exit(1);
  })
  .listen(port, "127.0.0.1", () => {
    console.log(`Serving website/build/ at http://localhost:${port}/live (Ctrl-C to stop)`);
  });

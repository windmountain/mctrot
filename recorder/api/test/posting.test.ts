import assert from "node:assert/strict";
import { test } from "node:test";
import { auth, ORIGIN, setup, TOKEN } from "./helpers.ts";

type App = Awaited<ReturnType<typeof setup>>["app"];

// Signs in with the token, as the page does the first time; returns the cookie.
async function signIn(app: App): Promise<string> {
  const res = await app.inject({ method: "POST", url: "/auth/token", payload: { token: TOKEN } });
  assert.equal(res.statusCode, 200);
  const setCookie = res.headers["set-cookie"];
  const header = Array.isArray(setCookie) ? setCookie[0] : setCookie;
  assert.ok(header);
  assert.match(header, /HttpOnly/i);
  assert.match(header, /SameSite=Strict/i);
  assert.match(header, /Secure/i);
  return header.split(";")[0]!;
}

const fromPage = (cookie: string) => ({ cookie, origin: ORIGIN });

test("a text post with the token is recorded once, and shows in /live", async () => {
  const { app } = await setup();
  const post = { id: "p1", ts: Date.now(), type: "text", text: "  hello from 125th  " };
  const first = await app.inject({ method: "POST", url: "/posts", headers: auth, payload: post });
  assert.equal(first.statusCode, 201);
  const retry = await app.inject({ method: "POST", url: "/posts", headers: auth, payload: post });
  assert.equal(retry.statusCode, 200);
  assert.equal(retry.json().recorded, false);
  const live = (await app.inject({ url: "/live" })).json();
  assert.equal(live.posts.length, 1);
  assert.equal(live.posts[0].text, "hello from 125th");
  assert.equal(live.posts[0].at, null); // no GPS yet
});

test("posts need text, and not too much", async () => {
  const { app } = await setup();
  const post = (text: string) =>
    app.inject({ method: "POST", url: "/posts", headers: auth, payload: { id: "x", type: "text", text } });
  assert.equal((await post("   ")).statusCode, 400);
  assert.equal((await post("a".repeat(1001))).statusCode, 400);
});

test("/auth/me before and after signing in with the token", async () => {
  const { app } = await setup();
  const before = (await app.inject({ url: "/auth/me" })).json();
  assert.deepEqual(before, { signedIn: false, passkeys: 0, canSignIn: true });
  const cookie = await signIn(app);
  const after = (await app.inject({ url: "/auth/me", headers: { cookie } })).json();
  assert.equal(after.signedIn, true);
});

test("a wrong token doesn't sign in", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "POST", url: "/auth/token", payload: { token: "nope" } });
  assert.equal(res.statusCode, 401);
  assert.equal(res.headers["set-cookie"], undefined);
});

test("signed in, the page can tap Visit and post", async () => {
  const { app } = await setup();
  const cookie = await signIn(app);
  const tap = await app.inject({ method: "POST", url: "/visits", headers: fromPage(cookie), payload: { id: "t1" } });
  assert.equal(tap.statusCode, 201);
  const post = await app.inject({
    method: "POST",
    url: "/posts",
    headers: fromPage(cookie),
    payload: { id: "p1", type: "text", text: "hi" },
  });
  assert.equal(post.statusCode, 201);
});

test("the session cookie is refused from another site's origin", async () => {
  const { app } = await setup();
  const cookie = await signIn(app);
  const res = await app.inject({
    method: "POST",
    url: "/visits",
    headers: { cookie, origin: "https://evil.example" },
    payload: { id: "t1" },
  });
  assert.equal(res.statusCode, 401);
});

test("a tampered or expired cookie doesn't count", async () => {
  const { app } = await setup();
  const cookie = await signIn(app);
  const [name, value] = cookie.split("=") as [string, string];
  const [, sig] = decodeURIComponent(value).split(".");
  const forged = `${name}=${encodeURIComponent(`${Date.now() + 1e12}.${sig}`)}`;
  const res = await app.inject({ url: "/auth/me", headers: { cookie: forged } });
  assert.equal(res.json().signedIn, false);
});

test("signing out clears the cookie", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "POST", url: "/auth/signout" });
  const header = String(res.headers["set-cookie"]);
  assert.match(header, /mctrot_session=;/);
});

test("passkeys: registering needs a session; signing in needs a registered one", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "POST", url: "/auth/register/options" })).statusCode, 401);
  const cookie = await signIn(app);
  const options = await app.inject({ method: "POST", url: "/auth/register/options", headers: fromPage(cookie) });
  assert.equal(options.statusCode, 200);
  const body = options.json();
  assert.ok(body.flowId);
  assert.equal(body.options.rp.id, "example.test");
  assert.equal(body.options.authenticatorSelection.userVerification, "required");
  // A made-up response doesn't verify.
  const verify = await app.inject({
    method: "POST",
    url: "/auth/register/verify",
    headers: fromPage(cookie),
    payload: { flowId: body.flowId, response: { id: "x", rawId: "x", type: "public-key", response: {} } },
  });
  assert.equal(verify.statusCode, 400);
  assert.equal((await app.inject({ method: "POST", url: "/auth/login/options" })).statusCode, 409);
});

test("the upload page and its scripts are served, locked down", async () => {
  const { app } = await setup();
  for (const [url, type] of [
    ["/post", "text/html"],
    ["/post/app.js", "text/javascript"],
    ["/post/webauthn.js", "text/javascript"],
    ["/post/manifest.webmanifest", "application/manifest+json"],
  ] as const) {
    const res = await app.inject({ url });
    assert.equal(res.statusCode, 200, url);
    assert.ok(String(res.headers["content-type"]).startsWith(type), url);
    assert.match(String(res.headers["content-security-policy"]), /default-src 'self'/, url);
  }
});

import assert from "node:assert/strict";
import { test } from "node:test";
import { auth, ORIGIN, setup, SITE, TOKEN } from "./helpers.ts";

type Setup = Awaited<ReturnType<typeof setup>>;
type App = Setup["app"];

const form = (fields: Record<string, string>) => new URLSearchParams(fields).toString();
const formHeaders = { "content-type": "application/x-www-form-urlencoded", origin: ORIGIN };

function cookieFrom(res: { headers: Record<string, unknown> }): string {
  const setCookie = res.headers["set-cookie"];
  const header = (Array.isArray(setCookie) ? setCookie : [setCookie]).find((c) => String(c).startsWith("mctrot_guest="));
  assert.ok(header, "expected a guest cookie");
  assert.match(String(header), /HttpOnly/i);
  assert.match(String(header), /SameSite=Lax/i);
  return String(header).split(";")[0]!;
}

function lastCode(mail: Setup["mail"]): string {
  const m = mail.at(-1);
  assert.ok(m);
  const code = m.subject.match(/(\d{3}) (\d{3})/);
  assert.ok(code);
  return code[1]! + code[2]!;
}

// Signs up a guest all the way: code, verify, profile. Returns the cookie.
async function signUp(s: Setup, email = "fan@example.com", name = "Fan"): Promise<string> {
  const sent = await s.app.inject({ method: "POST", url: "/account/code", headers: formHeaders, payload: form({ email }) });
  assert.equal(sent.statusCode, 200);
  const verified = await s.app.inject({
    method: "POST",
    url: "/account/verify",
    headers: formHeaders,
    payload: form({ email, code: lastCode(s.mail) }),
  });
  assert.equal(verified.statusCode, 200);
  assert.match(verified.body, /Almost done/);
  // The welcome form's redirect back to the site must be allowed, or the
  // browser drops it with no feedback.
  assert.match(String(verified.headers["content-security-policy"]), new RegExp(`form-action 'self' ${SITE}(;|$)`));
  const cookie = cookieFrom(verified);
  const profile = await s.app.inject({
    method: "POST",
    url: "/account/profile",
    headers: { ...formHeaders, cookie },
    payload: form({ name, link: "https://fan.example", age: "yes", back: `${SITE}/live` }),
  });
  assert.equal(profile.statusCode, 303);
  assert.equal(profile.headers.location, `${SITE}/live`);
  return cookie;
}

async function textPost(app: App, id = "p1") {
  const res = await app.inject({ method: "POST", url: "/posts", headers: auth, payload: { id, type: "text", text: "hi" } });
  assert.equal(res.statusCode, 201);
}

const fromSite = (cookie?: string) => ({ origin: SITE, ...(cookie ? { cookie } : {}) });

async function signInWriter(app: App): Promise<string> {
  const res = await app.inject({ method: "POST", url: "/auth/token", payload: { token: TOKEN } });
  const c = res.headers["set-cookie"];
  return String(Array.isArray(c) ? c[0] : c).split(";")[0]!;
}

test("sign up with an emailed code, then sign in again later", async () => {
  const s = await setup({ ingestToken: TOKEN });
  const page = await s.app.inject({ url: "/account" });
  assert.match(page.body, /Email me a code/);

  const cookie = await signUp(s);
  assert.equal(s.mail.length, 1);
  assert.equal(s.mail[0]!.to, "fan@example.com");

  const me = (await s.app.inject({ url: "/guests/feed", headers: fromSite(cookie) })).json();
  assert.deepEqual(me.me, { displayName: "Fan", complete: true });

  // Sign out, then sign back in: no profile form the second time.
  const out = await s.app.inject({ method: "POST", url: "/account/signout", headers: { ...formHeaders, cookie } });
  assert.equal(out.statusCode, 303);
  assert.equal((await s.app.inject({ url: "/guests/feed", headers: fromSite(cookie) })).json().me, null);

  // Same address in another case is the same account.
  await s.app.inject({ method: "POST", url: "/account/code", headers: formHeaders, payload: form({ email: "FAN@example.com" }) });
  const again = await s.app.inject({
    method: "POST",
    url: "/account/verify",
    headers: formHeaders,
    payload: form({ email: "FAN@example.com", code: lastCode(s.mail) }),
  });
  assert.equal(again.statusCode, 303);
  assert.equal(s.db.prepare("select count(*) from guest_accounts").pluck().get(), 1);
});

test("signing out from /live, and only from the site", async () => {
  const s = await setup({ ingestToken: TOKEN });
  const live = await signUp(s);
  const elsewhere = await s.app.inject({ method: "POST", url: "/guests/signout", headers: { cookie: live, origin: "https://evil.example" } });
  assert.equal(elsewhere.statusCode, 403);
  assert.notEqual((await s.app.inject({ url: "/guests/feed", headers: fromSite(live) })).json().me, null);
  const fromLive = await s.app.inject({ method: "POST", url: "/guests/signout", headers: fromSite(live) });
  assert.equal(fromLive.statusCode, 200);
  assert.equal(fromLive.headers["access-control-allow-credentials"], "true");
  assert.equal((await s.app.inject({ url: "/guests/feed", headers: fromSite(live) })).json().me, null);
});

test("a wrong code counts; five wrong and it's gone", async () => {
  const s = await setup({ ingestToken: TOKEN });
  await s.app.inject({ method: "POST", url: "/account/code", headers: formHeaders, payload: form({ email: "a@b.co" }) });
  const right = lastCode(s.mail);
  const wrong = right === "000000" ? "111111" : "000000";
  for (let i = 0; i < 5; i++) {
    const res = await s.app.inject({ method: "POST", url: "/account/verify", headers: formHeaders, payload: form({ email: "a@b.co", code: wrong }) });
    assert.equal(res.statusCode, 400);
  }
  const late = await s.app.inject({ method: "POST", url: "/account/verify", headers: formHeaders, payload: form({ email: "a@b.co", code: right }) });
  assert.equal(late.statusCode, 400);
  assert.match(late.body, /expired/);
});

test("codes can't be asked for again within a minute", async () => {
  const s = await setup({ ingestToken: TOKEN });
  for (let i = 0; i < 3; i++) {
    await s.app.inject({ method: "POST", url: "/account/code", headers: formHeaders, payload: form({ email: "a@b.co" }) });
  }
  assert.equal(s.mail.length, 1);
});

test("forms from another origin are refused", async () => {
  const s = await setup({ ingestToken: TOKEN });
  const res = await s.app.inject({
    method: "POST",
    url: "/account/code",
    headers: { "content-type": "application/x-www-form-urlencoded", origin: "https://evil.example" },
    payload: form({ email: "a@b.co" }),
  });
  assert.equal(res.statusCode, 403);
  assert.equal(s.mail.length, 0);
});

test("back only ever goes to our own site", async () => {
  const s = await setup({ ingestToken: TOKEN });
  const page = await s.app.inject({ url: "/account?back=https://evil.example/x" });
  assert.doesNotMatch(page.body, /evil/);
  assert.match(page.body, new RegExp(`${SITE}/live`));
});

test("the profile needs a name and the 16+ box", async () => {
  const s = await setup({ ingestToken: TOKEN });
  await s.app.inject({ method: "POST", url: "/account/code", headers: formHeaders, payload: form({ email: "a@b.co" }) });
  const v = await s.app.inject({ method: "POST", url: "/account/verify", headers: formHeaders, payload: form({ email: "a@b.co", code: lastCode(s.mail) }) });
  const cookie = cookieFrom(v);
  const noAge = await s.app.inject({ method: "POST", url: "/account/profile", headers: { ...formHeaders, cookie }, payload: form({ name: "X" }) });
  assert.equal(noAge.statusCode, 400);
  assert.match(noAge.body, /16 or older/);
  const badLink = await s.app.inject({
    method: "POST",
    url: "/account/profile",
    headers: { ...formHeaders, cookie },
    payload: form({ name: "X", age: "yes", link: "javascript:alert(1)" }),
  });
  assert.equal(badLink.statusCode, 400);
  // Unfinished, the guest can't like yet.
  const like = await s.app.inject({ method: "POST", url: "/guests/likes", headers: fromSite(cookie), payload: { postId: "p1", liked: true } });
  assert.equal(like.statusCode, 403);
});

test("likes are private; comments wait for approval; only the author sees them pending", async () => {
  const s = await setup({ ingestToken: TOKEN });
  await textPost(s.app);
  const fan = await signUp(s, "fan@example.com", "Fan");
  const other = await signUp(s, "other@example.com", "Other");

  const like = await s.app.inject({ method: "POST", url: "/guests/likes", headers: fromSite(fan), payload: { postId: "p1", liked: true } });
  assert.equal(like.statusCode, 200);
  assert.equal(like.headers["access-control-allow-origin"], SITE);
  assert.equal(like.headers["access-control-allow-credentials"], "true");
  await s.app.inject({ method: "POST", url: "/guests/likes", headers: fromSite(fan), payload: { postId: "p1", liked: true } });

  const c = await s.app.inject({ method: "POST", url: "/guests/comments", headers: fromSite(fan), payload: { postId: "p1", text: " great " } });
  assert.equal(c.statusCode, 201);
  const commentId = c.json().id;

  const asFan = (await s.app.inject({ url: "/guests/feed", headers: fromSite(fan) })).json().posts.p1;
  assert.equal("likes" in asFan, false);
  assert.equal(asFan.liked, true);
  assert.equal(asFan.comments.length, 0);
  assert.equal(asFan.pending[0].text, "great");
  // Someone else sees nothing of the fan's like or waiting comment.
  const asOther = (await s.app.inject({ url: "/guests/feed", headers: fromSite(other) })).json().posts.p1;
  assert.equal(asOther, undefined);

  // Moderation from the upload page.
  const writer = await signInWriter(s.app);
  const q = (await s.app.inject({ url: "/guests/queue", headers: { cookie: writer, origin: ORIGIN } })).json();
  assert.equal(q.items.length, 1);
  assert.equal(q.items[0].author.email, "fan@example.com");
  const ok = await s.app.inject({
    method: "POST",
    url: `/guests/comments/${commentId}/decision`,
    headers: { cookie: writer, origin: ORIGIN },
    payload: { status: "approved" },
  });
  assert.equal(ok.statusCode, 200);

  const anon = (await s.app.inject({ url: "/guests/feed" })).json();
  assert.equal(anon.me, null);
  assert.deepEqual(
    anon.posts.p1.comments.map((x: { name: string; text: string; link: string }) => [x.name, x.text, x.link]),
    [["Fan", "great", "https://fan.example"]],
  );
  // Emails never reach the public feed.
  assert.doesNotMatch(JSON.stringify(anon), /example\.com/);

  // Guests can't moderate.
  const nope = await s.app.inject({ url: "/guests/queue", headers: fromSite(fan) });
  assert.equal(nope.statusCode, 401);
});

test("likes and comments only on public posts, and need sign-in", async () => {
  const s = await setup({ ingestToken: TOKEN });
  const fan = await signUp(s);
  const missing = await s.app.inject({ method: "POST", url: "/guests/likes", headers: fromSite(fan), payload: { postId: "nope", liked: true } });
  assert.equal(missing.statusCode, 404);
  await textPost(s.app);
  const anon = await s.app.inject({ method: "POST", url: "/guests/comments", headers: fromSite(), payload: { postId: "p1", text: "x" } });
  assert.equal(anon.statusCode, 401);
  const evil = await s.app.inject({
    method: "POST",
    url: "/guests/comments",
    headers: { cookie: fan, origin: "https://evil.example" },
    payload: { postId: "p1", text: "x" },
  });
  assert.equal(evil.statusCode, 403);
});

test("anyone can report an approved comment; it goes back in the queue", async () => {
  const s = await setup({ ingestToken: TOKEN });
  await textPost(s.app);
  const fan = await signUp(s);
  const id = (await s.app.inject({ method: "POST", url: "/guests/comments", headers: fromSite(fan), payload: { postId: "p1", text: "hm" } })).json().id;
  // Pending comments can't be reported: nobody else can see them.
  const early = await s.app.inject({ method: "POST", url: "/guests/reports", headers: fromSite(), payload: { commentId: id, reason: "rude" } });
  assert.equal(early.statusCode, 404);
  const writer = { cookie: await signInWriter(s.app), origin: ORIGIN };
  await s.app.inject({ method: "POST", url: `/guests/comments/${id}/decision`, headers: writer, payload: { status: "approved" } });
  assert.equal((await s.app.inject({ url: "/guests/queue", headers: writer })).json().items.length, 0);

  const report = await s.app.inject({ method: "POST", url: "/guests/reports", headers: fromSite(), payload: { commentId: id, reason: "rude" } });
  assert.equal(report.statusCode, 201);
  const q = (await s.app.inject({ url: "/guests/queue", headers: writer })).json();
  assert.equal(q.items[0].reports[0].reason, "rude");

  await s.app.inject({ method: "POST", url: `/guests/comments/${id}/decision`, headers: writer, payload: { status: "rejected" } });
  assert.equal((await s.app.inject({ url: "/guests/queue", headers: writer })).json().items.length, 0);
  assert.equal((await s.app.inject({ url: "/guests/feed" })).json().posts.p1, undefined);
});

test("download my data, then close the account: everything goes", async () => {
  const s = await setup({ ingestToken: TOKEN });
  await textPost(s.app);
  const fan = await signUp(s);
  await s.app.inject({ method: "POST", url: "/guests/likes", headers: fromSite(fan), payload: { postId: "p1", liked: true } });
  await s.app.inject({ method: "POST", url: "/guests/comments", headers: fromSite(fan), payload: { postId: "p1", text: "mine" } });

  const exp = await s.app.inject({ url: "/account/export", headers: { cookie: fan } });
  assert.equal(exp.statusCode, 200);
  assert.match(String(exp.headers["content-disposition"]), /attachment/);
  const data = exp.json();
  assert.equal(data.account.email, "fan@example.com");
  assert.equal(data.likes.length, 1);
  assert.equal(data.comments[0].text, "mine");

  const notTicked = await s.app.inject({ method: "POST", url: "/account/close", headers: { ...formHeaders, cookie: fan }, payload: form({}) });
  assert.equal(notTicked.statusCode, 400);
  const closed = await s.app.inject({
    method: "POST",
    url: "/account/close",
    headers: { ...formHeaders, cookie: fan },
    payload: form({ confirm: "yes" }),
  });
  assert.equal(closed.statusCode, 200);
  assert.match(closed.body, /Account closed/);
  for (const table of ["guest_accounts", "guest_sessions", "guest_likes", "guest_comments", "guest_codes"]) {
    assert.equal(s.db.prepare(`select count(*) from ${table}`).pluck().get(), 0, table);
  }
});

test("change email with a code sent to the new address", async () => {
  const s = await setup({ ingestToken: TOKEN });
  const fan = await signUp(s);
  await signUp(s, "taken@example.com", "T");
  const taken = await s.app.inject({ method: "POST", url: "/account/email", headers: { ...formHeaders, cookie: fan }, payload: form({ email: "taken@example.com" }) });
  assert.equal(taken.statusCode, 409);
  const sent = await s.app.inject({ method: "POST", url: "/account/email", headers: { ...formHeaders, cookie: fan }, payload: form({ email: "new@example.com" }) });
  assert.equal(sent.statusCode, 200);
  assert.equal(s.mail.at(-1)!.to, "new@example.com");
  const ok = await s.app.inject({
    method: "POST",
    url: "/account/email/verify",
    headers: { ...formHeaders, cookie: fan },
    payload: form({ email: "new@example.com", code: lastCode(s.mail) }),
  });
  assert.equal(ok.statusCode, 200);
  assert.match(ok.body, /Email changed/);
  assert.equal(s.db.prepare("select count(*) from guest_accounts where email = 'new@example.com'").pluck().get(), 1);
});

test("deleting a post deletes its likes and comments", async () => {
  const s = await setup({ ingestToken: TOKEN });
  await textPost(s.app);
  const fan = await signUp(s);
  await s.app.inject({ method: "POST", url: "/guests/likes", headers: fromSite(fan), payload: { postId: "p1", liked: true } });
  await s.app.inject({ method: "POST", url: "/guests/comments", headers: fromSite(fan), payload: { postId: "p1", text: "x" } });
  const del = await s.app.inject({ method: "DELETE", url: "/posts/p1", headers: auth });
  assert.equal(del.statusCode, 200);
  assert.equal(s.db.prepare("select count(*) from guest_comments").pluck().get(), 0);
  assert.equal(s.db.prepare("select count(*) from guest_likes").pluck().get(), 0);
});

test("preflight from the site is allowed", async () => {
  const s = await setup({ ingestToken: TOKEN });
  const res = await s.app.inject({ method: "OPTIONS", url: "/guests/likes", headers: { origin: SITE, "access-control-request-method": "POST" } });
  assert.equal(res.statusCode, 204);
  assert.equal(res.headers["access-control-allow-origin"], SITE);
  assert.match(String(res.headers["access-control-allow-headers"]), /content-type/);
});

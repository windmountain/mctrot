// The account pages at api.mctrot.nyc/account: plain HTML forms, no
// JavaScript, in the website's colours. Every value is escaped.
import type { Account } from "./store.ts";
import { MAX_LINK, MAX_NAME } from "./store.ts";

export const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

export type PageContext = {
  siteOrigin: string; // https://mctrot.nyc
  back: string; // where to go when done (checked: on our site)
};

const STYLE = `
  :root { --bg: #FFD100; --ink: #0D0D08; --muted: #5c5845; --bad: #b42318; color-scheme: light;
          font-family: Helvetica, Arial, sans-serif; }
  html { background: var(--bg); }
  body { margin: 0; color: var(--ink); background: var(--bg); }
  main { max-width: 30rem; margin: 0 auto; padding: 24px 16px 48px; }
  .card { background: #fff; padding: 20px; margin: 16px 0; }
  h1 { font-size: 2rem; letter-spacing: -0.02em; margin: 0 0 4px; }
  h1 a { color: inherit; text-decoration: none; }
  h2 { font-size: 1.15rem; margin: 0 0 12px; }
  label { display: block; margin: 12px 0 4px; font-weight: 600; }
  label.check { display: flex; gap: 8px; align-items: flex-start; font-weight: 400; }
  label.check input { width: auto; margin-top: 3px; }
  input[type=email], input[type=text], input[type=url], input[inputmode=numeric] {
    font: inherit; width: 100%; box-sizing: border-box; padding: 10px; border: 2px solid var(--ink); }
  input[inputmode=numeric] { font-size: 1.6rem; letter-spacing: 0.3em; text-align: center; }
  button { font: inherit; font-weight: 700; border: 0; padding: 12px 18px; margin-top: 16px;
           background: var(--ink); color: #fff; cursor: pointer; }
  button.secondary { background: #eee; color: var(--ink); }
  button.danger { background: var(--bad); }
  .small { font-size: 0.9rem; color: var(--muted); }
  .error { color: var(--bad); font-weight: 600; }
  form.inline { display: inline; }
  a { color: inherit; }
`;

export function page(ctx: PageContext, title: string, body: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <title>${esc(title)} — McTrot</title>
  <link rel="icon" href="${esc(ctx.siteOrigin)}/favicon.svg" type="image/svg+xml">
  <style>${STYLE}</style>
</head>
<body>
  <main>
    <h1><a href="${esc(ctx.siteOrigin)}/">McTrot</a></h1>
    ${body}
    <p class="small">
      <a href="${esc(ctx.back)}">Back to McTrot</a> ·
      <a href="${esc(ctx.siteOrigin)}/privacy.html">Privacy</a> ·
      <a href="mailto:privacy@mctrot.nyc">privacy@mctrot.nyc</a>
    </p>
  </main>
</body>
</html>`;
}

const hiddenBack = (ctx: PageContext) => `<input type="hidden" name="back" value="${esc(ctx.back)}">`;
const err = (message?: string) => (message ? `<p class="error" role="alert">${esc(message)}</p>` : "");

export function signInPage(ctx: PageContext, opts: { email?: string; error?: string } = {}) {
  return page(
    ctx,
    "Sign in",
    `<div class="card">
      <h2>Sign in to like and comment</h2>
      <p>We'll email you a six-digit code. No password. New here? The same code makes your account.</p>
      ${err(opts.error)}
      <form method="post" action="/account/code">
        ${hiddenBack(ctx)}
        <label for="email">Email</label>
        <input id="email" name="email" type="email" required autocomplete="email" value="${esc(opts.email ?? "")}">
        <button>Email me a code</button>
      </form>
      <p class="small">Your email is never shown to anyone.
        See the <a href="${esc(ctx.siteOrigin)}/privacy.html">privacy policy</a>.</p>
    </div>`,
  );
}

export function codePage(
  ctx: PageContext,
  opts: { email: string; action: string; error?: string; heading?: string },
) {
  return page(
    ctx,
    "Enter your code",
    `<div class="card">
      <h2>${esc(opts.heading ?? "Check your email")}</h2>
      <p>We sent a six-digit code to <strong>${esc(opts.email)}</strong>. It works for 10 minutes.</p>
      ${err(opts.error)}
      <form method="post" action="${esc(opts.action)}">
        ${hiddenBack(ctx)}
        <input type="hidden" name="email" value="${esc(opts.email)}">
        <label for="code">Code</label>
        <input id="code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]{6,7}" required autofocus>
        <button>Continue</button>
      </form>
      <p class="small">Nothing arrived? Check spam, or <a href="/account?back=${encodeURIComponent(ctx.back)}">start again</a>.</p>
    </div>`,
  );
}

function profileFields(account: Account) {
  return `
    <label for="name">Name shown with your comments</label>
    <input id="name" name="name" type="text" required maxlength="${MAX_NAME}" value="${esc(account.displayName ?? "")}">
    <label for="link">Link (optional)</label>
    <input id="link" name="link" type="url" maxlength="${MAX_LINK}" placeholder="https://" value="${esc(account.link ?? "")}">
    <p class="small">Your name and link are public, next to your approved comments, and are kept in the McTrot archive
      until you delete them or close your account.</p>
    ${
      account.ageConfirmedAt === null
        ? `<label class="check"><input type="checkbox" name="age" value="yes" required> I'm 16 or older.</label>`
        : ""
    }
    <label class="check"><input type="checkbox" name="announcements" value="yes"${
      account.announcementsAt !== null ? " checked" : ""
    }> Email me three times a year with news about McTrot.</label>`;
}

export function welcomePage(ctx: PageContext, account: Account, error?: string) {
  return page(
    ctx,
    "Welcome",
    `<div class="card">
      <h2>Almost done</h2>
      <p>Signed in as <strong>${esc(account.email)}</strong>.</p>
      ${err(error)}
      <form method="post" action="/account/profile">
        ${hiddenBack(ctx)}
        ${profileFields(account)}
        <button>Save</button>
      </form>
    </div>`,
  );
}

export function accountPage(ctx: PageContext, account: Account, opts: { notice?: string; error?: string } = {}) {
  return page(
    ctx,
    "Your account",
    `${opts.notice ? `<p role="status"><strong>${esc(opts.notice)}</strong></p>` : ""}
    <div class="card">
      <h2>Profile</h2>
      ${err(opts.error)}
      <form method="post" action="/account/profile">
        ${hiddenBack(ctx)}
        ${profileFields(account)}
        <button>Save</button>
      </form>
    </div>
    <div class="card">
      <h2>Email</h2>
      <p><strong>${esc(account.email)}</strong></p>
      <form method="post" action="/account/email">
        ${hiddenBack(ctx)}
        <label for="new-email">Change to</label>
        <input id="new-email" name="email" type="email" required autocomplete="email">
        <button class="secondary">Send a code to the new address</button>
      </form>
    </div>
    <div class="card">
      <h2>Your data</h2>
      <p>Everything we keep about your account, as a JSON file.</p>
      <p><a href="/account/export">Download my data</a></p>
      <form method="post" action="/account/signout">
        ${hiddenBack(ctx)}
        <button class="secondary">Sign out</button>
      </form>
    </div>
    <div class="card">
      <h2>Close account</h2>
      <p>Deletes your account, every comment and like, right away. This can't be undone.
        Comments already copied into the McTrot archive are removed from it too.</p>
      <form method="post" action="/account/close">
        ${hiddenBack(ctx)}
        <label class="check"><input type="checkbox" name="confirm" value="yes" required> Yes, delete everything.</label>
        <button class="danger">Close my account</button>
      </form>
    </div>`,
  );
}

export function messagePage(ctx: PageContext, title: string, message: string) {
  return page(ctx, title, `<div class="card"><h2>${esc(title)}</h2><p>${esc(message)}</p></div>`);
}

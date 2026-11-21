// Guest accounts' routes, all in one Fastify plugin so the feature comes
// out cleanly (see schema.ts):
//
//   /account/...   HTML forms on api.mctrot.nyc: sign in with an emailed
//                  code, profile, change email, download data, close.
//   /guests/...    JSON for /live (on mctrot.nyc, with credentials):
//                  likes, comments, reports; and for the upload page:
//                  the moderation queue.
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import type { Db } from "../db.ts";
import type { Mailer } from "./mail.ts";
import { accountPage, codePage, messagePage, type PageContext, signInPage, welcomePage } from "./pages.ts";
import {
  type Account,
  accountByEmail,
  addComment,
  addReport,
  changeEmail,
  Codes,
  commentsSince,
  complete,
  decide,
  deleteAccount,
  deleteOwnComment,
  endSession,
  ensureGuestTables,
  exportAccount,
  feed,
  findOrCreate,
  MAX_COMMENT,
  MAX_LINK,
  MAX_NAME,
  MAX_REASON,
  postIsPublic,
  queue,
  saveProfile,
  sessionAccount,
  setLike,
  startSession,
  sweep,
} from "./store.ts";

export const GUEST_COOKIE = "mctrot_guest";

export type GuestDeps = {
  db: Db;
  // Hashes sign-in codes (the API's session secret).
  secret: string;
  // Where these pages are served (https://api.mctrot.nyc), and the public
  // site whose /live calls the JSON routes (https://mctrot.nyc).
  apiOrigin: string;
  siteOrigin: string;
  mailer: Mailer;
  // The upload page's sign-in, for moderation.
  writer: (req: FastifyRequest, reply: FastifyReply) => boolean;
};

// How often codes may be sent: per address, per IP, and in all.
const CODE_GAP_MS = 60_000;
const PER_IP_PER_HOUR = 20;
const ALL_PER_HOUR = 300;
const COMMENTS_PER_10_MIN = 10;

class Limiter {
  private hits = new Map<string, number[]>();
  private max: number;
  private windowMs: number;
  constructor(max: number, windowMs: number) {
    this.max = max;
    this.windowMs = windowMs;
  }
  take(key: string, now = Date.now()): boolean {
    const recent = (this.hits.get(key) ?? []).filter((t) => t > now - this.windowMs);
    if (recent.length >= this.max) {
      this.hits.set(key, recent);
      return false;
    }
    recent.push(now);
    this.hits.set(key, recent);
    if (this.hits.size > 10_000) this.hits.clear(); // never grows without bound
    return true;
  }
}

const Email = z.string().trim().max(254).pipe(z.email());
const Code = z.string().trim().regex(/^\d{3} ?\d{3}$/);
const Link = z
  .string()
  .trim()
  .max(MAX_LINK)
  .refine((s) => {
    try {
      const u = new URL(s);
      return u.protocol === "https:" || u.protocol === "http:";
    } catch {
      return false;
    }
  });

type Form = Record<string, string | undefined>;

export async function registerGuests(app: FastifyInstance, deps: GuestDeps) {
  const { db, apiOrigin, siteOrigin } = deps;
  ensureGuestTables(db);
  sweep(db);
  const codes = new Codes(db, deps.secret);
  const perIp = new Limiter(PER_IP_PER_HOUR, 3_600_000);
  const overall = new Limiter(ALL_PER_HOUR, 3_600_000);
  const secure = apiOrigin.startsWith("https://");

  await app.register(async (scope) => {
    // HTML forms post as application/x-www-form-urlencoded; only here.
    scope.addContentTypeParser(
      "application/x-www-form-urlencoded",
      { parseAs: "string", bodyLimit: 16_384 },
      (_req, body, done) => done(null, Object.fromEntries(new URLSearchParams(body as string))),
    );

    // --- Helpers -------------------------------------------------------------

    // Only ever send people back to our own site.
    const backFrom = (req: FastifyRequest): string => {
      const raw =
        (req.body as Form | undefined)?.back ?? (req.query as Form | undefined)?.back ?? `${siteOrigin}/live`;
      try {
        const u = new URL(raw);
        if (u.origin === siteOrigin || u.origin === apiOrigin) return u.toString();
      } catch {}
      return `${siteOrigin}/live`;
    };
    const ctxOf = (req: FastifyRequest): PageContext => ({ siteOrigin, back: backFrom(req) });

    const html = (reply: FastifyReply, body: string, code = 200) =>
      reply
        .code(code)
        .header("content-type", "text/html; charset=utf-8")
        .header("cache-control", "no-store")
        // form-action also covers where a form's redirect goes: verify,
        // profile and sign out send the guest back to the site, and a
        // browser blocks that silently unless the site is allowed here.
        .header("content-security-policy", `default-src 'none'; style-src 'unsafe-inline'; img-src 'self' ${siteOrigin}; form-action 'self' ${siteOrigin}; frame-ancestors 'none'`)
        .header("referrer-policy", "same-origin")
        .send(body);

    const token = (req: FastifyRequest) => req.cookies[GUEST_COOKIE];
    const viewer = (req: FastifyRequest): Account | null => sessionAccount(db, token(req));

    const signIn = (reply: FastifyReply, accountId: number) => {
      const s = startSession(db, accountId);
      reply.setCookie(GUEST_COOKIE, s.token, { httpOnly: true, secure, sameSite: "lax", path: "/", maxAge: s.maxAge });
    };
    const signOut = (req: FastifyRequest, reply: FastifyReply) => {
      endSession(db, token(req));
      reply.clearCookie(GUEST_COOKIE, { path: "/" });
    };

    // Browsers send Origin with every POST; anything not from our pages
    // (or /live, for the JSON routes) is turned away, which stops other
    // sites from acting with a guest's cookie.
    const fromOrigins = (req: FastifyRequest, reply: FastifyReply, allowed: string[]): boolean => {
      const origin = req.headers.origin;
      if (origin !== undefined && allowed.includes(origin)) return true;
      reply.code(403).send({ error: "not from a McTrot page" });
      return false;
    };
    const formOk = (req: FastifyRequest, reply: FastifyReply) => fromOrigins(req, reply, [apiOrigin]);
    const jsonOk = (req: FastifyRequest, reply: FastifyReply) => fromOrigins(req, reply, [siteOrigin, apiOrigin]);

    const sendCode = async (
      req: FastifyRequest,
      email: string,
      purpose: "signin" | "email",
      accountId: number | null,
    ): Promise<"sent" | "wait" | "busy" | "failed"> => {
      const last = codes.lastSent(email, purpose);
      if (last !== null && Date.now() - last < CODE_GAP_MS) return "wait";
      if (!perIp.take(req.ip) || !overall.take("all")) return "busy";
      sweep(db);
      const code = codes.issue(email, purpose, accountId);
      const spaced = `${code.slice(0, 3)} ${code.slice(3)}`;
      try {
        await deps.mailer({
          to: email,
          subject: `${spaced} is your McTrot code`,
          text:
            `Your McTrot code is ${spaced}\n\n` +
            `It works for 10 minutes. If you didn't ask for it, ignore this email: ` +
            `nothing happens without the code.\n\n` +
            `McTrot · ${siteOrigin}\nPrivacy: ${siteOrigin}/privacy.html · privacy@mctrot.nyc\n`,
        });
        return "sent";
      } catch (e) {
        req.log.error({ err: String(e) }, "sending a guest code failed");
        return "failed";
      }
    };
    const codeTrouble = {
      wait: "We just sent a code to that address. Wait a minute before asking for another.",
      busy: "Too many codes requested. Try again in a while.",
      failed: "We couldn't send the email just now. Try again in a few minutes.",
    };

    // --- Pages ---------------------------------------------------------------

    scope.get("/account", async (req, reply) => {
      const me = viewer(req);
      const ctx = ctxOf(req);
      if (!me) return html(reply, signInPage(ctx));
      if (!complete(me)) return html(reply, welcomePage(ctx, me));
      return html(reply, accountPage(ctx, me));
    });

    scope.post("/account/code", async (req, reply) => {
      if (!formOk(req, reply)) return reply;
      const ctx = ctxOf(req);
      const raw = (req.body as Form | undefined)?.email ?? "";
      const email = Email.safeParse(raw);
      if (!email.success) return html(reply, signInPage(ctx, { email: raw, error: "That doesn't look like an email address." }), 400);
      const result = await sendCode(req, email.data, "signin", null);
      if (result === "sent" || result === "wait") {
        // "wait" still shows the code form: the last code is still good.
        return html(reply, codePage(ctx, { email: email.data, action: "/account/verify" }));
      }
      return html(reply, signInPage(ctx, { email: email.data, error: codeTrouble[result] }), 429);
    });

    scope.post("/account/verify", async (req, reply) => {
      if (!formOk(req, reply)) return reply;
      const ctx = ctxOf(req);
      const body = (req.body ?? {}) as Form;
      const email = Email.safeParse(body.email ?? "");
      if (!email.success) return reply.redirect(`/account?back=${encodeURIComponent(ctx.back)}`);
      const code = Code.safeParse(body.code ?? "");
      const checked = code.success
        ? codes.check(email.data, "signin", code.data)
        : ({ ok: false, reason: "wrong" } as const);
      if (!checked.ok) {
        if (checked.reason === "expired") {
          return html(reply, signInPage(ctx, { email: email.data, error: "That code has expired. Ask for a new one." }), 400);
        }
        return html(
          reply,
          codePage(ctx, { email: email.data, action: "/account/verify", error: "That code isn't right." }),
          400,
        );
      }
      const account = findOrCreate(db, email.data);
      signIn(reply, account.id);
      if (!complete(account)) return html(reply, welcomePage(ctx, account));
      return reply.redirect(ctx.back, 303);
    });

    scope.post("/account/profile", async (req, reply) => {
      if (!formOk(req, reply)) return reply;
      const ctx = ctxOf(req);
      const me = viewer(req);
      if (!me) return html(reply, signInPage(ctx), 401);
      const body = (req.body ?? {}) as Form;
      const name = (body.name ?? "").trim().replace(/\s+/g, " ");
      const rawLink = (body.link ?? "").trim();
      const link = rawLink === "" ? null : Link.safeParse(rawLink);
      const again = (error: string) =>
        html(reply, complete(me) ? accountPage(ctx, me, { error }) : welcomePage(ctx, me, error), 400);
      if (name.length < 1 || name.length > MAX_NAME) return again(`Your name needs 1 to ${MAX_NAME} characters.`);
      if (link !== null && !link.success) return again("The link needs to be a web address starting with https://.");
      const ageConfirmed = me.ageConfirmedAt !== null || body.age === "yes";
      if (!ageConfirmed) return again("You need to be 16 or older to have an account.");
      saveProfile(db, me.id, {
        displayName: name,
        link: link === null ? null : link.data,
        ageConfirmed,
        announcements: body.announcements === "yes",
      });
      if (!complete(me)) return reply.redirect(ctx.back, 303);
      return html(reply, accountPage(ctx, viewer(req)!, { notice: "Saved." }));
    });

    scope.post("/account/email", async (req, reply) => {
      if (!formOk(req, reply)) return reply;
      const ctx = ctxOf(req);
      const me = viewer(req);
      if (!me) return html(reply, signInPage(ctx), 401);
      const email = Email.safeParse((req.body as Form | undefined)?.email ?? "");
      if (!email.success) return html(reply, accountPage(ctx, me, { error: "That doesn't look like an email address." }), 400);
      if (accountByEmail(db, email.data)) {
        return html(reply, accountPage(ctx, me, { error: "Another account already uses that address." }), 409);
      }
      const result = await sendCode(req, email.data, "email", me.id);
      if (result !== "sent" && result !== "wait") return html(reply, accountPage(ctx, me, { error: codeTrouble[result] }), 429);
      return html(
        reply,
        codePage(ctx, { email: email.data, action: "/account/email/verify", heading: "Confirm your new address" }),
      );
    });

    scope.post("/account/email/verify", async (req, reply) => {
      if (!formOk(req, reply)) return reply;
      const ctx = ctxOf(req);
      const me = viewer(req);
      if (!me) return html(reply, signInPage(ctx), 401);
      const body = (req.body ?? {}) as Form;
      const email = Email.safeParse(body.email ?? "");
      const code = Code.safeParse(body.code ?? "");
      if (!email.success) return html(reply, accountPage(ctx, me), 400);
      const checked = code.success ? codes.check(email.data, "email", code.data) : ({ ok: false, reason: "wrong" } as const);
      if (!checked.ok || checked.accountId !== me.id) {
        const error = !checked.ok && checked.reason === "wrong" ? "That code isn't right." : "That code has expired.";
        if (!checked.ok && checked.reason === "wrong") {
          return html(
            reply,
            codePage(ctx, { email: email.data, action: "/account/email/verify", heading: "Confirm your new address", error }),
            400,
          );
        }
        return html(reply, accountPage(ctx, me, { error }), 400);
      }
      if (!changeEmail(db, me.id, email.data)) {
        return html(reply, accountPage(ctx, me, { error: "Another account already uses that address." }), 409);
      }
      return html(reply, accountPage(ctx, viewer(req)!, { notice: "Email changed." }));
    });

    // A link, not a form: GETs are safe, and only the guest's own cookie
    // (SameSite=Lax) can fetch it.
    scope.get("/account/export", async (req, reply) => {
      const me = viewer(req);
      if (!me) return reply.redirect("/account", 303);
      const data = exportAccount(db, me.id);
      const day = new Date().toISOString().slice(0, 10);
      return reply
        .header("cache-control", "no-store")
        .header("content-type", "application/json; charset=utf-8")
        .header("content-disposition", `attachment; filename="mctrot-account-${day}.json"`)
        .send(JSON.stringify(data, null, 2));
    });

    scope.post("/account/signout", async (req, reply) => {
      if (!formOk(req, reply)) return reply;
      signOut(req, reply);
      return reply.redirect(ctxOf(req).back, 303);
    });

    scope.post("/account/close", async (req, reply) => {
      if (!formOk(req, reply)) return reply;
      const ctx = ctxOf(req);
      const me = viewer(req);
      if (!me) return html(reply, signInPage(ctx), 401);
      if ((req.body as Form | undefined)?.confirm !== "yes") {
        return html(reply, accountPage(ctx, me, { error: "Tick the box to confirm." }), 400);
      }
      deleteAccount(db, me.id);
      reply.clearCookie(GUEST_COOKIE, { path: "/" });
      req.log.info({ guest: me.id }, "guest account closed");
      return html(
        reply,
        messagePage(ctx, "Account closed", "Your account, comments and likes are deleted. Thanks for following McTrot."),
      );
    });

    // --- JSON for /live --------------------------------------------------------

    // /live is on another origin and sends the guest cookie, so it gets
    // CORS with credentials; only from the site itself.
    scope.addHook("onRequest", async (req, reply) => {
      if (!req.url.startsWith("/guests/")) return;
      if (req.headers.origin === siteOrigin) {
        reply.header("access-control-allow-origin", siteOrigin);
        reply.header("access-control-allow-credentials", "true");
      }
      reply.header("vary", "Origin");
      reply.header("cache-control", "no-store");
    });
    scope.options("/guests/*", async (_req, reply) =>
      reply
        .header("access-control-allow-methods", "GET, POST, DELETE")
        .header("access-control-allow-headers", "content-type")
        .header("access-control-max-age", "600")
        .code(204)
        .send(),
    );

    const meJson = (me: Account | null) =>
      me && { displayName: me.displayName, complete: complete(me) };

    // Who's signed in, and every post's likes and comments as they see them.
    scope.get("/guests/feed", async (req) => {
      const me = viewer(req);
      return { me: meJson(me), accountUrl: `${apiOrigin}/account`, posts: feed(db, me) };
    });

    // Sign out from /live (the form at /account/signout only takes posts
    // from api.mctrot.nyc's own pages).
    scope.post("/guests/signout", async (req, reply) => {
      if (!jsonOk(req, reply)) return reply;
      signOut(req, reply);
      return { signedOut: true };
    });

    // The signed-in guest who may like and comment; otherwise replies.
    const participant = (req: FastifyRequest, reply: FastifyReply): Account | null => {
      if (!jsonOk(req, reply)) return null;
      const me = viewer(req);
      if (!me) {
        reply.code(401).send({ error: "sign in first" });
        return null;
      }
      if (!complete(me)) {
        reply.code(403).send({ error: "finish your profile first" });
        return null;
      }
      return me;
    };

    const LikeBody = z.object({ postId: z.string().min(1).max(100), liked: z.boolean() });
    scope.post("/guests/likes", async (req, reply) => {
      const me = participant(req, reply);
      if (!me) return reply;
      const body = LikeBody.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "expected {postId, liked}" });
      if (!postIsPublic(db, body.data.postId)) return reply.code(404).send({ error: "no such post" });
      setLike(db, me.id, body.data.postId, body.data.liked);
      return { postId: body.data.postId, liked: body.data.liked };
    });

    const CommentBody = z.object({ postId: z.string().min(1).max(100), text: z.string().trim().min(1).max(MAX_COMMENT) });
    scope.post("/guests/comments", async (req, reply) => {
      const me = participant(req, reply);
      if (!me) return reply;
      const body = CommentBody.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: `expected {postId, text: 1 to ${MAX_COMMENT} characters}` });
      if (!postIsPublic(db, body.data.postId)) return reply.code(404).send({ error: "no such post" });
      if (commentsSince(db, me.id, Date.now() - 10 * 60_000) >= COMMENTS_PER_10_MIN) {
        return reply.code(429).send({ error: "slow down: too many comments" });
      }
      const id = addComment(db, me.id, body.data.postId, body.data.text);
      reply.code(201);
      return { id, status: "pending" };
    });

    scope.delete("/guests/comments/:id", async (req, reply) => {
      const me = participant(req, reply);
      if (!me) return reply;
      const id = Number((req.params as { id: string }).id);
      if (!Number.isInteger(id) || !deleteOwnComment(db, me.id, id)) {
        return reply.code(404).send({ error: "no such comment of yours" });
      }
      return { deleted: id };
    });

    // Anyone may report a comment, signed in or not.
    const ReportBody = z.object({ commentId: z.number().int(), reason: z.string().trim().min(1).max(MAX_REASON) });
    scope.post("/guests/reports", async (req, reply) => {
      if (!jsonOk(req, reply)) return reply;
      const body = ReportBody.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: `expected {commentId, reason: 1 to ${MAX_REASON} characters}` });
      if (!perIp.take(`report:${req.ip}`)) return reply.code(429).send({ error: "too many reports" });
      if (!addReport(db, body.data.commentId, viewer(req)?.id ?? null, body.data.reason)) {
        return reply.code(404).send({ error: "no such comment" });
      }
      reply.code(201);
      return { reported: body.data.commentId };
    });

    // --- Moderation, from the upload page ------------------------------------

    scope.get("/guests/queue", async (req, reply) => {
      if (!deps.writer(req, reply)) return reply;
      return { items: queue(db) };
    });

    const Decision = z.object({ status: z.enum(["approved", "rejected"]) });
    scope.post("/guests/comments/:id/decision", async (req, reply) => {
      if (!deps.writer(req, reply)) return reply;
      const id = Number((req.params as { id: string }).id);
      const body = Decision.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: 'expected {status: "approved" or "rejected"}' });
      if (!Number.isInteger(id) || !decide(db, id, body.data.status)) {
        return reply.code(404).send({ error: "no such comment" });
      }
      return { id, status: body.data.status };
    });

    // For abuse: closes a guest's account, as if they had.
    scope.delete("/guests/accounts/:id", async (req, reply) => {
      if (!deps.writer(req, reply)) return reply;
      const id = Number((req.params as { id: string }).id);
      if (!Number.isInteger(id) || !deleteAccount(db, id)) return reply.code(404).send({ error: "no such account" });
      return { deleted: id };
    });
  });
}

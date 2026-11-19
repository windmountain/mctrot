// Guest accounts in the database: codes, sessions, profiles, likes,
// comments, reports, and everything-about-me for export.
import { createHash, createHmac, randomBytes, randomInt } from "node:crypto";
import type { Db } from "../db.ts";
import { GUEST_SCHEMA } from "./schema.ts";

export const CODE_MS = 10 * 60_000;
export const CODE_TRIES = 5;
export const SESSION_DAYS = 90;
// An account that verified its email but never finished its profile.
export const UNFINISHED_MS = 24 * 3_600_000;
export const MAX_COMMENT = 500;
export const MAX_NAME = 40;
export const MAX_LINK = 200;
export const MAX_REASON = 500;

export function ensureGuestTables(db: Db) {
  db.exec(GUEST_SCHEMA);
}

const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");

export type Purpose = "signin" | "email";

export type Account = {
  id: number;
  email: string;
  displayName: string | null;
  link: string | null;
  ageConfirmedAt: number | null;
  announcementsAt: number | null;
  createdAt: number;
};

type AccountRow = {
  id: number;
  email: string;
  display_name: string | null;
  link: string | null;
  age_confirmed_at: number | null;
  announcements_at: number | null;
  created_at: number;
};

const toAccount = (r: AccountRow): Account => ({
  id: r.id,
  email: r.email,
  displayName: r.display_name,
  link: r.link,
  ageConfirmedAt: r.age_confirmed_at,
  announcementsAt: r.announcements_at,
  createdAt: r.created_at,
});

// Can like and comment: has a name and said they're 16 or older.
export const complete = (a: Account) => a.displayName !== null && a.ageConfirmedAt !== null;

// --- Codes -------------------------------------------------------------------

export class Codes {
  private db: Db;
  private secret: string;
  constructor(db: Db, secret: string) {
    this.db = db;
    this.secret = secret;
  }

  private hash(email: string, purpose: Purpose, code: string) {
    return createHmac("sha256", this.secret).update(`${purpose}:${email.toLowerCase()}:${code}`).digest("hex");
  }

  // A fresh six-digit code for this address, replacing any earlier one.
  issue(email: string, purpose: Purpose, accountId: number | null, now = Date.now()): string {
    const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    this.db
      .prepare(
        `insert or replace into guest_codes (email, purpose, account_id, code_hash, tries, sent_at, expires_at)
         values (?, ?, ?, ?, 0, ?, ?)`,
      )
      .run(email, purpose, accountId, this.hash(email, purpose, code), now, now + CODE_MS);
    return code;
  }

  // When the last code went to this address, for rate limiting.
  lastSent(email: string, purpose: Purpose): number | null {
    return (
      (this.db
        .prepare("select sent_at from guest_codes where email = ? and purpose = ?")
        .pluck()
        .get(email, purpose) as number | undefined) ?? null
    );
  }

  // Right code: used up, and returns the account it was for (if any).
  // Wrong: counts a try; too many, and the code is gone.
  check(
    email: string,
    purpose: Purpose,
    code: string,
    now = Date.now(),
  ): { ok: true; accountId: number | null } | { ok: false; reason: "wrong" | "expired" } {
    const row = this.db
      .prepare("select code_hash, tries, expires_at, account_id from guest_codes where email = ? and purpose = ?")
      .get(email, purpose) as
      | { code_hash: string; tries: number; expires_at: number; account_id: number | null }
      | undefined;
    if (!row || row.expires_at < now || row.tries >= CODE_TRIES) {
      if (row) this.db.prepare("delete from guest_codes where email = ? and purpose = ?").run(email, purpose);
      return { ok: false, reason: "expired" };
    }
    const given = this.hash(email, purpose, code.replace(/\s/g, ""));
    if (given !== row.code_hash) {
      this.db.prepare("update guest_codes set tries = tries + 1 where email = ? and purpose = ?").run(email, purpose);
      return { ok: false, reason: row.tries + 1 >= CODE_TRIES ? "expired" : "wrong" };
    }
    this.db.prepare("delete from guest_codes where email = ? and purpose = ?").run(email, purpose);
    return { ok: true, accountId: row.account_id };
  }
}

// --- Accounts and sessions ---------------------------------------------------

export function accountByEmail(db: Db, email: string): Account | null {
  const row = db.prepare("select * from guest_accounts where email = ?").get(email) as AccountRow | undefined;
  return row ? toAccount(row) : null;
}

export function accountById(db: Db, id: number): Account | null {
  const row = db.prepare("select * from guest_accounts where id = ?").get(id) as AccountRow | undefined;
  return row ? toAccount(row) : null;
}

// Signing in with a verified address: the account, made if it's new.
export function findOrCreate(db: Db, email: string, now = Date.now()): Account {
  db.prepare(
    `insert into guest_accounts (email, created_at, last_seen_at) values (?, ?, ?)
     on conflict (email) do nothing`,
  ).run(email, now, now);
  return accountByEmail(db, email)!;
}

export function startSession(db: Db, accountId: number, now = Date.now()): { token: string; maxAge: number } {
  const token = randomBytes(32).toString("base64url");
  const maxAge = SESSION_DAYS * 86_400;
  db.prepare("insert into guest_sessions (token_hash, account_id, created_at, expires_at) values (?, ?, ?, ?)").run(
    sha256(token),
    accountId,
    now,
    now + maxAge * 1000,
  );
  return { token, maxAge };
}

export function sessionAccount(db: Db, token: string | undefined, now = Date.now()): Account | null {
  if (!token) return null;
  const row = db
    .prepare(
      `select a.* from guest_sessions s join guest_accounts a on a.id = s.account_id
       where s.token_hash = ? and s.expires_at > ?`,
    )
    .get(sha256(token), now) as AccountRow | undefined;
  if (!row) return null;
  db.prepare("update guest_accounts set last_seen_at = ? where id = ?").run(now, row.id);
  return toAccount(row);
}

export function endSession(db: Db, token: string | undefined) {
  if (token) db.prepare("delete from guest_sessions where token_hash = ?").run(sha256(token));
}

export type Profile = { displayName: string; link: string | null; ageConfirmed: boolean; announcements: boolean };

export function saveProfile(db: Db, accountId: number, p: Profile, now = Date.now()) {
  db.prepare(
    `update guest_accounts set
       display_name = ?, link = ?,
       age_confirmed_at = coalesce(age_confirmed_at, ?),
       announcements_at = case when ? then coalesce(announcements_at, ?) else null end
     where id = ?`,
  ).run(p.displayName, p.link, p.ageConfirmed ? now : null, p.announcements ? 1 : 0, now, accountId);
}

// False if another account already has that address.
export function changeEmail(db: Db, accountId: number, email: string): boolean {
  if (accountByEmail(db, email)) return false;
  db.prepare("update guest_accounts set email = ? where id = ?").run(email, accountId);
  return true;
}

// Closing an account: every row about it goes (see schema.ts).
export function deleteAccount(db: Db, accountId: number): boolean {
  return db.prepare("delete from guest_accounts where id = ?").run(accountId).changes === 1;
}

// Expired codes and sessions, and accounts never finished.
export function sweep(db: Db, now = Date.now()) {
  db.prepare("delete from guest_codes where expires_at < ?").run(now);
  db.prepare("delete from guest_sessions where expires_at < ?").run(now);
  db.prepare("delete from guest_accounts where display_name is null and created_at < ?").run(now - UNFINISHED_MS);
}

// --- Likes and comments ------------------------------------------------------

// Only posts the public can see take likes and comments.
export function postIsPublic(db: Db, postId: string): boolean {
  return (
    db
      .prepare("select 1 from posts where id = ? and hidden = 0 and status = 'ready' and paired_into is null")
      .get(postId) !== undefined
  );
}

export function setLike(db: Db, accountId: number, postId: string, liked: boolean, now = Date.now()) {
  if (liked) {
    db.prepare("insert or ignore into guest_likes (account_id, post_id, created_at) values (?, ?, ?)").run(
      accountId,
      postId,
      now,
    );
  } else {
    db.prepare("delete from guest_likes where account_id = ? and post_id = ?").run(accountId, postId);
  }
}

export function addComment(db: Db, accountId: number, postId: string, text: string, now = Date.now()): number {
  return Number(
    db
      .prepare("insert into guest_comments (account_id, post_id, text, created_at) values (?, ?, ?, ?)")
      .run(accountId, postId, text, now).lastInsertRowid,
  );
}

export function deleteOwnComment(db: Db, accountId: number, commentId: number): boolean {
  return (
    db.prepare("delete from guest_comments where id = ? and account_id = ?").run(commentId, accountId).changes === 1
  );
}

export function commentsSince(db: Db, accountId: number, since: number): number {
  return db
    .prepare("select count(*) from guest_comments where account_id = ? and created_at > ?")
    .pluck()
    .get(accountId, since) as number;
}

export type PublicComment = {
  id: number;
  name: string;
  link: string | null;
  text: string;
  ts: number;
  mine: boolean;
};

export type PostSocial = {
  likes: number;
  liked: boolean;
  comments: PublicComment[]; // approved, oldest first
  pending: { id: number; text: string; ts: number }[]; // mine, awaiting approval
};

// Likes and comments for every post that has any, as one viewer sees them.
export function feed(db: Db, viewer: Account | null): Record<string, PostSocial> {
  const out: Record<string, PostSocial> = {};
  const get = (postId: string) =>
    (out[postId] ??= { likes: 0, liked: false, comments: [], pending: [] });
  for (const r of db.prepare("select post_id, count(*) as n from guest_likes group by post_id").all() as {
    post_id: string;
    n: number;
  }[]) {
    get(r.post_id).likes = r.n;
  }
  if (viewer) {
    for (const postId of db
      .prepare("select post_id from guest_likes where account_id = ?")
      .pluck()
      .all(viewer.id) as string[]) {
      get(postId).liked = true;
    }
  }
  const comments = db
    .prepare(
      `select c.id, c.post_id, c.text, c.created_at, c.account_id, c.status, a.display_name, a.link
       from guest_comments c join guest_accounts a on a.id = c.account_id
       where c.status = 'approved' or (c.status = 'pending' and c.account_id = ?)
       order by c.created_at`,
    )
    .all(viewer?.id ?? -1) as {
    id: number;
    post_id: string;
    text: string;
    created_at: number;
    account_id: number;
    status: string;
    display_name: string | null;
    link: string | null;
  }[];
  for (const c of comments) {
    if (c.status === "pending") {
      get(c.post_id).pending.push({ id: c.id, text: c.text, ts: c.created_at });
    } else {
      get(c.post_id).comments.push({
        id: c.id,
        name: c.display_name ?? "Guest",
        link: c.link,
        text: c.text,
        ts: c.created_at,
        mine: c.account_id === viewer?.id,
      });
    }
  }
  return out;
}

export function addReport(db: Db, commentId: number, reporterId: number | null, reason: string, now = Date.now()) {
  const exists = db.prepare("select 1 from guest_comments where id = ? and status = 'approved'").get(commentId);
  if (!exists) return false;
  db.prepare("insert into guest_reports (comment_id, reporter_id, reason, created_at) values (?, ?, ?, ?)").run(
    commentId,
    reporterId,
    reason,
    now,
  );
  return true;
}

// --- Moderation (the upload page) --------------------------------------------

export type QueueItem = {
  id: number;
  postId: string;
  postText: string | null;
  postType: string;
  text: string;
  ts: number;
  status: "pending" | "approved" | "rejected";
  author: { id: number; name: string | null; email: string; link: string | null };
  reports: { id: number; reason: string; ts: number }[];
};

// What needs me: pending comments, and approved ones with open reports.
export function queue(db: Db): QueueItem[] {
  const rows = db
    .prepare(
      `select c.id, c.post_id, c.text, c.created_at, c.status, p.text as post_text, p.type as post_type,
              a.id as account_id, a.display_name, a.email, a.link
       from guest_comments c
       join guest_accounts a on a.id = c.account_id
       join posts p on p.id = c.post_id
       where c.status = 'pending'
          or exists (select 1 from guest_reports r where r.comment_id = c.id and r.resolved_at is null)
       order by c.created_at`,
    )
    .all() as {
    id: number;
    post_id: string;
    text: string;
    created_at: number;
    status: QueueItem["status"];
    post_text: string | null;
    post_type: string;
    account_id: number;
    display_name: string | null;
    email: string;
    link: string | null;
  }[];
  const reports = db.prepare(
    "select id, reason, created_at from guest_reports where comment_id = ? and resolved_at is null order by created_at",
  );
  return rows.map((r) => ({
    id: r.id,
    postId: r.post_id,
    postText: r.post_text,
    postType: r.post_type,
    text: r.text,
    ts: r.created_at,
    status: r.status,
    author: { id: r.account_id, name: r.display_name, email: r.email, link: r.link },
    reports: (reports.all(r.id) as { id: number; reason: string; created_at: number }[]).map((x) => ({
      id: x.id,
      reason: x.reason,
      ts: x.created_at,
    })),
  }));
}

// Approving or rejecting a comment also settles its open reports.
export function decide(db: Db, commentId: number, status: "approved" | "rejected", now = Date.now()): boolean {
  return db.transaction(() => {
    const changed =
      db.prepare("update guest_comments set status = ?, decided_at = ? where id = ?").run(status, now, commentId)
        .changes === 1;
    if (changed) {
      db.prepare("update guest_reports set resolved_at = ?, reporter_id = null where comment_id = ? and resolved_at is null").run(
        now,
        commentId,
      );
    }
    return changed;
  })();
}

// --- Export ------------------------------------------------------------------

// Everything kept about an account, for "Download my data".
export function exportAccount(db: Db, accountId: number) {
  const a = db.prepare("select * from guest_accounts where id = ?").get(accountId) as
    | (AccountRow & { last_seen_at: number })
    | undefined;
  if (!a) return null;
  const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());
  return {
    exportedAt: new Date().toISOString(),
    controller: "Wind Mountain LLC, New York, USA (privacy@mctrot.nyc)",
    account: {
      email: a.email,
      displayName: a.display_name,
      link: a.link,
      createdAt: iso(a.created_at),
      lastSeenAt: iso(a.last_seen_at),
      confirmed16OrOlderAt: iso(a.age_confirmed_at),
      announcementsOptInAt: iso(a.announcements_at),
    },
    sessions: (
      db.prepare("select created_at, expires_at from guest_sessions where account_id = ?").all(accountId) as {
        created_at: number;
        expires_at: number;
      }[]
    ).map((s) => ({ signedInAt: iso(s.created_at), expiresAt: iso(s.expires_at) })),
    likes: (
      db.prepare("select post_id, created_at from guest_likes where account_id = ?").all(accountId) as {
        post_id: string;
        created_at: number;
      }[]
    ).map((l) => ({ postId: l.post_id, likedAt: iso(l.created_at) })),
    comments: (
      db
        .prepare("select post_id, text, status, created_at, decided_at from guest_comments where account_id = ?")
        .all(accountId) as {
        post_id: string;
        text: string;
        status: string;
        created_at: number;
        decided_at: number | null;
      }[]
    ).map((c) => ({
      postId: c.post_id,
      text: c.text,
      status: c.status,
      postedAt: iso(c.created_at),
      decidedAt: iso(c.decided_at),
    })),
    reportsMade: (
      db
        .prepare("select comment_id, reason, created_at from guest_reports where reporter_id = ?")
        .all(accountId) as { comment_id: number; reason: string; created_at: number }[]
    ).map((r) => ({ commentId: r.comment_id, reason: r.reason, reportedAt: iso(r.created_at) })),
    note:
      "Server logs (kept 14 days) may also hold your IP address with the time and address of each request; " +
      "they aren't linked to your account. Ask privacy@mctrot.nyc for anything else.",
  };
}

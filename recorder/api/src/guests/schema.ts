// Guest accounts: people who sign in with their email to like and comment
// on posts. Kept apart from the event schema (../schema.ts) on purpose:
// these tables are created here, with "if not exists", only when guests
// are turned on, so the feature can be switched off or deleted without
// touching SCHEMA_VERSION or anything else. Removing it for good:
// delete src/guests/, its hook in app.ts and main.ts, and drop the
// guest_* tables (or let the next schema bump start a fresh file).
//
// Deleting an account deletes everything about it: every table below
// hangs off guest_accounts with "on delete cascade". Comments and likes
// also go when their post is deleted.
export const GUEST_SCHEMA = `
  create table if not exists guest_accounts (
    id integer primary key,
    email text not null unique collate nocase,
    display_name text,               -- null until they fill in their profile
    link text,                       -- optional, shown with their comments
    age_confirmed_at integer,        -- when they said they're 16 or older
    announcements_at integer,        -- when they opted in to event emails; null: no
    created_at integer not null,
    last_seen_at integer not null
  ) strict;

  -- One-time codes, emailed to sign in or to change an address. Only a
  -- hash is kept; a code dies after a few wrong tries or ten minutes.
  create table if not exists guest_codes (
    email text not null collate nocase,
    purpose text not null check (purpose in ('signin', 'email')),
    account_id integer references guest_accounts (id) on delete cascade, -- 'email': whose
    code_hash text not null,
    tries integer not null default 0,
    sent_at integer not null,
    expires_at integer not null,
    primary key (email, purpose)
  ) strict;

  -- Signed-in browsers. The cookie holds a random token; only its hash
  -- is kept, so a copy of the database can't sign anyone in.
  create table if not exists guest_sessions (
    token_hash text primary key,
    account_id integer not null references guest_accounts (id) on delete cascade,
    created_at integer not null,
    expires_at integer not null
  ) strict;
  create index if not exists guest_sessions_account on guest_sessions (account_id);

  create table if not exists guest_likes (
    account_id integer not null references guest_accounts (id) on delete cascade,
    post_id text not null references posts (id) on delete cascade,
    created_at integer not null,
    primary key (account_id, post_id)
  ) strict;
  create index if not exists guest_likes_post on guest_likes (post_id);

  -- Every comment waits for my approval before anyone else sees it.
  create table if not exists guest_comments (
    id integer primary key,
    account_id integer not null references guest_accounts (id) on delete cascade,
    post_id text not null references posts (id) on delete cascade,
    text text not null,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    created_at integer not null,
    decided_at integer
  ) strict;
  create index if not exists guest_comments_post on guest_comments (post_id, status);
  create index if not exists guest_comments_account on guest_comments (account_id);

  -- "Report this comment": anyone may, signed in or not (EU DSA notice
  -- and action). Reporter is kept only if signed in, and only until the
  -- report is resolved or their account closes.
  create table if not exists guest_reports (
    id integer primary key,
    comment_id integer not null references guest_comments (id) on delete cascade,
    reporter_id integer references guest_accounts (id) on delete set null,
    reason text not null,
    created_at integer not null,
    resolved_at integer
  ) strict;
`;

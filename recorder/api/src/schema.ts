// The whole database schema. There are no migrations: the recorder only
// has to live for one event, so when this changes, bump SCHEMA_VERSION and
// the API starts over with an empty database (see openDb). Once
// `recorder.live` is on (host/configuration.nix), it refuses to instead.
export const SCHEMA_VERSION = 3;

export const SCHEMA = `
  -- Every location fix from the phone, keyed by the phone's timestamp so
  -- retried and out-of-order batches sort themselves out. Which attempt a
  -- point belongs to follows from the attempt's start and stop times.
  create table points (
    ts integer primary key,        -- ms since epoch, phone clock
    lat real not null,
    lon real not null,
    accuracy real,                 -- metres, horizontal
    speed real,                    -- m/s
    battery real,                  -- 0..1
    received_at integer not null   -- ms since epoch, server clock
  ) strict;

  -- A McTrot attempt: open while ended_at is null. At most one is open.
  create table attempts (
    id integer primary key,
    started_at integer not null,   -- ms since epoch, server clock
    ended_at integer               -- ms since epoch; null while running
  ) strict;
  create unique index one_open_attempt on attempts ((1)) where ended_at is null;

  -- "I'm at a McDonald's": just a time. Which store it was is worked out
  -- from the GPS track each time it's needed (src/visits.ts), never stored.
  create table visit_taps (
    id text primary key,           -- from the phone, so retries don't duplicate
    ts integer not null,           -- ms since epoch, phone clock
    received_at integer not null   -- ms since epoch, server clock
  ) strict;

  -- Passkeys allowed to sign in to the upload page (Face ID on my phone).
  create table passkeys (
    id text primary key,           -- credential id, base64url
    public_key blob not null,
    counter integer not null,
    transports text not null,      -- JSON array
    created_at integer not null
  ) strict;

  -- What I post from the road. id comes from the phone's outbox, so a
  -- retried upload can't post twice. Where it was posted is worked out
  -- from the GPS track, like visits.
  create table posts (
    id text primary key,
    ts integer not null,           -- ms since epoch, phone clock (when written)
    type text not null check (type in ('text')),
    text text not null,
    hidden integer not null default 0,
    received_at integer not null
  ) strict;
`;

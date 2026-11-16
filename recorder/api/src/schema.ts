// The whole database schema. There are no migrations: the recorder only
// has to live for one event, so when this changes, bump SCHEMA_VERSION and
// the API starts over with an empty database (see openDb). Once
// `recorder.live` is on (host/configuration.nix), it refuses to instead.
export const SCHEMA_VERSION = 5;

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
  -- from the GPS track, like visits. A photo, video or voice post is
  -- "processing" until the worker (src/worker.ts) has made its files,
  -- under the media folder in a folder named for the post's id.
  --
  -- DoubleTake records the back and front cameras at once, as two videos
  -- named …_A.MOV and …_B.MOV with the same time and length. The worker
  -- pairs them (src/pairs.ts) into a 'pair' post; the two clips stay as
  -- video posts, paired_into the pair, and are no longer shown on their own.
  create table posts (
    id text primary key,
    ts integer not null,           -- ms since epoch, phone clock (when made)
    type text not null check (type in ('text', 'photo', 'video', 'voice', 'pair')),
    text text,                     -- the text of a text post
    status text not null default 'ready' check (status in ('processing', 'ready', 'failed')),
    error text,                    -- why processing failed
    media_path text,               -- photo: full size; video: .mp4; voice: .m4a
    thumb_path text,               -- photo: ~400 px
    poster_path text,              -- video: a frame
    width integer,
    height integer,
    duration_ms integer,           -- video and voice
    letter text check (letter in ('A', 'B')), -- a video: DoubleTake's camera, from the filename
    paired_into text,              -- a video: the pair post it's part of
    pair_order text check (pair_order in ('AB', 'BA')), -- a pair: which clip comes first
    alt_media_path text,           -- a pair: the other order's cut (media_path is AB's)
    alt_poster_path text,          -- a pair: its poster
    hidden integer not null default 0,
    received_at integer not null
  ) strict;

  -- The weather in central Manhattan (src/weather.ts), fetched every 10
  -- minutes by mctrot-weather. Imperial units, as /live shows them. Open-
  -- Meteo's current conditions update every 15 minutes, so neighbouring
  -- rows can repeat a reading (same observed_at).
  create table weather (
    fetched_at integer primary key, -- ms since epoch, server clock
    observed_at integer not null,  -- ms since epoch: the reading's own time
    temperature_f real,
    feels_like_f real,
    humidity_pct real,
    precipitation_in real,         -- in the reading's 15 minutes
    weather_code integer,          -- WMO code
    cloud_cover_pct real,
    wind_mph real,
    gust_mph real,
    wind_from_deg real,
    is_day integer,
    raw text not null              -- Open-Meteo's whole response, for later
  ) strict;

  -- Media waiting to be processed: one per uploaded file.
  create table jobs (
    id integer primary key,
    post_id text not null unique references posts (id),
    upload_path text not null,     -- the finished upload (tus file store); '' for a pair
    content_type text not null,
    status text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
    attempts integer not null default 0,
    error text,
    created_at integer not null,
    updated_at integer not null
  ) strict;
`;

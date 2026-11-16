// The whole database schema. There are no migrations: the recorder only
// has to live for one event, so when this changes, bump SCHEMA_VERSION and
// the API starts over with an empty database (see openDb). Before going
// live, set MCTROT_DB_RESET=never in host/api.nix so it can't.
export const SCHEMA_VERSION = 1;

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
`;

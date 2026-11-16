import type { Db } from "./db.ts";

export type Attempt = { id: number; startedAt: number; endedAt: number | null };

type Row = { id: number; started_at: number; ended_at: number | null };
const fromRow = (r: Row): Attempt => ({ id: r.id, startedAt: r.started_at, endedAt: r.ended_at });

export function openAttempt(db: Db): Attempt | null {
  const row = db.prepare("select * from attempts where ended_at is null").get() as Row | undefined;
  return row ? fromRow(row) : null;
}

// The running attempt, or else the most recent one: what /live shows.
export function latestAttempt(db: Db): Attempt | null {
  const row = db
    .prepare("select * from attempts order by started_at desc, id desc limit 1")
    .get() as Row | undefined;
  return row ? fromRow(row) : null;
}

// Starting while one is running returns the running one, so a retried
// request can't open a second attempt.
export function startAttempt(db: Db, now = Date.now()): { attempt: Attempt; created: boolean } {
  return db.transaction(() => {
    const running = openAttempt(db);
    if (running) return { attempt: running, created: false };
    const id = db.prepare("insert into attempts (started_at) values (?)").run(now)
      .lastInsertRowid as number;
    return { attempt: { id, startedAt: now, endedAt: null }, created: true };
  })();
}

// Null when nothing is running.
export function stopAttempt(db: Db, now = Date.now()): Attempt | null {
  return db.transaction(() => {
    const running = openAttempt(db);
    if (!running) return null;
    db.prepare("update attempts set ended_at = ? where id = ?").run(now, running.id);
    return { ...running, endedAt: now };
  })();
}

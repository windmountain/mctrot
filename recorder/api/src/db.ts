import Database from "better-sqlite3";

export type Db = Database.Database;

// One SQLite file on the Volume. WAL lets /live read while ingest writes.
export function openDb(path: string): Db {
  const db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  return db;
}

export type DbStatus =
  | { ok: true; path: string; sqlite: string; journalMode: string }
  | { ok: false; path: string; error: string };

// A real query, not just "the handle exists": proves the file is readable.
export function dbStatus(db: Db): DbStatus {
  try {
    const { v } = db.prepare("select sqlite_version() as v").get() as { v: string };
    const journalMode = db.pragma("journal_mode", { simple: true }) as string;
    return { ok: true, path: db.name, sqlite: v, journalMode };
  } catch (err) {
    return { ok: false, path: db.name, error: String(err) };
  }
}

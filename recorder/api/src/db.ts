import { existsSync, renameSync, rmSync } from "node:fs";
import Database from "better-sqlite3";
import { SCHEMA, SCHEMA_VERSION } from "./schema.ts";

export type Db = Database.Database;

// What to do when the file holds a different schema version:
// "reset" moves the old file aside and starts empty (before going live);
// "never" refuses to start, so event data can't be wiped by a deploy.
export type ResetPolicy = "reset" | "never";

export type Opened = { db: Db; archived?: string };

function connect(path: string): Db {
  const db = new Database(path);
  // WAL lets /live read while ingest writes.
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  return db;
}

function isEmpty(db: Db): boolean {
  return db.prepare("select count(*) as n from sqlite_schema").pluck().get() === 0;
}

export function openDb(path: string, policy: ResetPolicy = "reset"): Opened {
  let db = connect(path);
  const found = db.pragma("user_version", { simple: true }) as number;
  if (found === SCHEMA_VERSION) return { db };

  let archived: string | undefined;
  if (!isEmpty(db)) {
    db.close();
    if (policy === "never") {
      throw new Error(
        `${path} has schema version ${found}, this code expects ${SCHEMA_VERSION}, ` +
          `and MCTROT_DB_RESET=never. Refusing to start.`,
      );
    }
    if (path !== ":memory:") {
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      archived = `${path}.v${found}-${stamp}.bak`;
      renameSync(path, archived);
      for (const suffix of ["-wal", "-shm"]) {
        if (existsSync(path + suffix)) rmSync(path + suffix);
      }
    }
    db = connect(path);
  }

  db.transaction(() => {
    db.exec(SCHEMA);
    db.pragma(`user_version = ${SCHEMA_VERSION}`);
  })();
  return { db, archived };
}

export type DbStatus =
  | { ok: true; path: string; sqlite: string; journalMode: string; schemaVersion: number }
  | { ok: false; path: string; error: string };

// A real query, not just "the handle exists": proves the file is readable.
export function dbStatus(db: Db): DbStatus {
  try {
    const sqlite = db.prepare("select sqlite_version()").pluck().get() as string;
    const journalMode = db.pragma("journal_mode", { simple: true }) as string;
    const schemaVersion = db.pragma("user_version", { simple: true }) as number;
    return { ok: true, path: db.name, sqlite, journalMode, schemaVersion };
  } catch (err) {
    return { ok: false, path: db.name, error: String(err) };
  }
}

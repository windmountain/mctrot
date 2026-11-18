import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { nowPlaying, programReader, type RadioProgram } from "../src/radio.ts";
import { setup } from "./helpers.ts";

// A 10-minute show at 5:00 AM New York: three entries, the last a break.
const START = Date.parse("2026-11-21T10:00:00Z") / 1000;
const PROGRAM: RadioProgram = {
  file: "show-abc.flac",
  startsAt: START,
  endsAt: START + 600,
  before: { artist: "McTrot radio", title: "On air at 5:00 AM" },
  after: { artist: "McTrot radio", title: "Off air" },
  entries: [
    { offset: 0, duration: 240.5, artist: "Dune", title: "Are You Ready To Fly", album: "Are You Ready To Fly (Remixes)", year: "1995", kind: "track" },
    { offset: 240.5, duration: 354.5, artist: "Donna Summer", title: "I Feel Love", album: "I Remember Yesterday", year: "1977", kind: "track" },
    { offset: 595, duration: 5, artist: "McTrot Radio", title: "Break", album: null, year: null, kind: "break" },
  ],
};
const at = (seconds: number) => (START + seconds) * 1000;

test("before the show: holding, with the first entry next", () => {
  const radio = nowPlaying(PROGRAM, at(-60));
  assert.equal(radio?.status, "before");
  assert.deepEqual(radio?.current, { artist: "McTrot radio", title: "On air at 5:00 AM", album: null, year: null, from: null, to: at(0), kind: "holding" });
  assert.equal(radio?.next?.title, "Are You Ready To Fly");
});

test("during the show: the entry on now, and the one after", () => {
  const radio = nowPlaying(PROGRAM, at(300));
  assert.equal(radio?.status, "on");
  assert.deepEqual(radio?.current, { artist: "Donna Summer", title: "I Feel Love", album: "I Remember Yesterday", year: "1977", from: at(240.5), to: at(595), kind: "track" });
  assert.deepEqual(radio?.next, { artist: "McTrot Radio", title: "Break", album: null, year: null, from: at(595), to: at(600), kind: "break" });
});

test("an entry starts on its first millisecond", () => {
  assert.equal(nowPlaying(PROGRAM, at(240.5))?.current.title, "I Feel Love");
  assert.equal(nowPlaying(PROGRAM, at(240.499))?.current.title, "Are You Ready To Fly");
});

test("the last entry's next is off air; after the show there's nothing next", () => {
  assert.equal(nowPlaying(PROGRAM, at(597))?.next?.title, "Off air");
  const after = nowPlaying(PROGRAM, at(600));
  assert.equal(after?.status, "after");
  assert.deepEqual(after?.current, { artist: "McTrot radio", title: "Off air", album: null, year: null, from: at(600), to: null, kind: "holding" });
  assert.equal(after?.next, null);
});

test("no program: no radio", () => {
  assert.equal(nowPlaying(null, at(0)), null);
});

test("programReader: off air until the show file is there, and reads a new program", () => {
  const dir = mkdtempSync(join(tmpdir(), "mctrot-station-"));
  const path = join(dir, "program.json");
  const warnings: string[] = [];
  const read = programReader(path, (w) => warnings.push(w));
  assert.equal(read(), null, "no program.json yet");
  writeFileSync(path, JSON.stringify({ ...PROGRAM, about: "extra fields are fine" }));
  assert.equal(read(), null, "its show file isn't uploaded yet");
  writeFileSync(join(dir, "show-abc.flac"), "");
  assert.equal(read()?.entries.length, 3);
  writeFileSync(path, JSON.stringify({ ...PROGRAM, entries: PROGRAM.entries.slice(0, 1) }) + " ");
  assert.equal(read()?.entries.length, 1, "read again once it changes");
  writeFileSync(path, "{ half an upl");
  assert.equal(read(), null);
  assert.equal(warnings.length, 1, "a bad program is logged");
});

test("a program from before albums: album and year are null", () => {
  const old = { ...PROGRAM, entries: PROGRAM.entries.map(({ album: _a, year: _y, ...e }) => e) };
  const dir = mkdtempSync(join(tmpdir(), "mctrot-station-"));
  writeFileSync(join(dir, "program.json"), JSON.stringify(old));
  writeFileSync(join(dir, "show-abc.flac"), "");
  const radio = nowPlaying(programReader(join(dir, "program.json"))(), at(10));
  assert.equal(radio?.current.title, "Are You Ready To Fly");
  assert.equal(radio?.current.album, null);
});

test("GET /live: radio is null without a program", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ url: "/live" })).json().radio, null);
});

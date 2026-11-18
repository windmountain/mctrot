#!/usr/bin/env python3
"""Turns the radio tape and its spreadsheet into McTrot radio's show.

    radio_program.py Program.xlsx Tape.wav --date 2026-11-21 [--station-id ID.wav] [--out DIR]

Program.xlsx has two sheets:

1. The tracks on Tape.wav, in the order they're on it: '#', 'Song',
   'Artist', 'Duration' (minutes and seconds, as Excel's hours and
   minutes: 04:07 is 4 min 7 s).
2. The program: the order to play them in, by '#' (0 is a Break), with a
   'Start (Trot-relative)' column whose 0 row starts at the trot's start,
   and that start's clock time in the column after it.

The program plays back to back: the 0 row starts at the trot's start, the
rows before it end there, and each row after starts when the one before
ends. The sheet's other start times are ignored (they're each row's end).

Where each track starts and ends on the tape comes from the tape itself:
the silence between tracks nearest where the sheet's durations put the
boundary. Each track keeps the silence after it, so gaps sound as they do
on the tape. A Break plays the station ID (--station-id), or 5 seconds
of silence without one.

It writes two files into --out (default: the spreadsheet's folder):

- show-<hash>.flac: the whole program as one file. The name changes with
  the content, so a program.json never points at the wrong render.
- program.json: what's on when (host/radio.nix reads it from
  /var/lib/mctrot/station/, and so does the API for /live's now playing).

Upload both to the box, the audio first: Liquidsoap restarts on the new
program.json as soon as it lands.

Python's standard library, and ffmpeg on PATH.
"""

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import wave
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from zoneinfo import ZoneInfo

NEW_YORK = ZoneInfo("America/New_York")
RATE = 44100
CHANNELS = 2
WIDTH = 2  # bytes per sample: 16-bit
FRAME = CHANNELS * WIDTH

# The silence between tracks: quieter than this, for at least this long.
SILENCE_DB = -40
SILENCE_S = 0.25
# How far from where the sheet's durations put a boundary its silence can
# be (the sheet's durations are Spotify's, to the second; the tape's
# tracks can run a few seconds longer).
SEARCH_S = 15
BREAK_S = 5.0


def fail(message):
    sys.exit(f"radio_program: {message}")


# --- The spreadsheet -------------------------------------------------------
# Excel's "Strict Open XML" (which openpyxl can't read): read straight from
# the zip.


def local(tag):
    return tag.rsplit("}", 1)[-1]


def column(ref):
    return re.match(r"[A-Z]+", ref).group(0)


def read_sheets(path):
    """Each sheet as (name, rows), a row a dict of column letter to text."""
    with zipfile.ZipFile(path) as z:
        strings = []
        if "xl/sharedStrings.xml" in z.namelist():
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")):
                strings.append("".join(t.text or "" for t in si.iter() if local(t.tag) == "t"))
        workbook = ET.fromstring(z.read("xl/workbook.xml"))
        names = [s.get("name") for s in workbook.iter() if local(s.tag) == "sheet"]
        sheets = []
        for i, name in enumerate(names, 1):
            rows = []
            for row in ET.fromstring(z.read(f"xl/worksheets/sheet{i}.xml")).iter():
                if local(row.tag) != "row":
                    continue
                cells = {}
                for c in row:
                    if local(c.tag) != "c":
                        continue
                    v = next((x.text for x in c if local(x.tag) == "v"), None)
                    if v is None:
                        continue
                    cells[column(c.get("r"))] = strings[int(v)] if c.get("t") == "s" else v
                rows.append(cells)
            sheets.append((name, rows))
        return sheets


def table(rows):
    """The rows under the header row, as dicts keyed by header (and by
    column letter, for headerless columns)."""
    header = {letter: name.strip() for letter, name in rows[0].items()}
    return [{**cells, **{header[k]: v for k, v in cells.items() if k in header}} for cells in rows[1:] if cells]


def mended(text):
    """Text as it was meant: the sheet's came through a Mac Roman mix-up
    ("L√•psley" for "Låpsley"), so undo that where it reads as UTF-8."""
    text = (text or "").strip()
    try:
        fixed = text.encode("mac_roman").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        fixed = text
    return re.sub(r"\s+", " ", fixed)


def artists(text):
    """'Mobb Deep,Nick Morgan' as 'Mobb Deep, Nick Morgan' (and 'Tyler,
    The Creator' left alone)."""
    return re.sub(r",(?=\S)", ", ", mended(text))


def clock_seconds(value):
    """An Excel time ("04:07:00.0000000001"), as seconds of the day."""
    h, m, s = value.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def sheet_duration(value):
    """A 'Duration': minutes and seconds written as hours and minutes."""
    return clock_seconds(value) / 60


def is_zero(value):
    return value is not None and re.fullmatch(r"PT0H0M0(\.0*)?S|0(\.0*)?", value.strip()) is not None


# --- The tape --------------------------------------------------------------


def silences(tape):
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", str(tape), "-af", f"silencedetect=noise={SILENCE_DB}dB:d={SILENCE_S}", "-f", "null", "-"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        fail(f"ffmpeg couldn't read {tape}:\n{out.stderr[-2000:]}")
    starts = [float(m) for m in re.findall(r"silence_start: ([-\d.]+)", out.stderr)]
    ends = [float(m) for m in re.findall(r"silence_end: ([-\d.]+)", out.stderr)]
    return list(zip(starts, ends))


def boundaries(tracks, gaps, length):
    """Where each track starts on the tape, and where the last ends: the end
    of the silence nearest where the one before it should end."""
    starts = [0.0]
    for track in tracks[:-1]:
        expected = starts[-1] + track["duration"]
        near = [(s, e) for s, e in gaps if e > starts[-1] + 1 and s - SEARCH_S <= expected <= e + SEARCH_S]
        if not near:
            fail(
                f"no silence on the tape within {SEARCH_S} s of {fmt(expected)}, where #{track['n']} "
                f"({track['title']}) should end. Is the tape in the sheet's order?"
            )
        # The nearest by distance to the silence (0 inside it); of equals,
        # the later one, so a quiet patch at a track's end doesn't win.
        s, e = min(near, key=lambda g: (max(g[0] - expected, expected - g[1], 0), -g[1]))
        starts.append(e)
    starts.append(length)
    return starts


def fmt(seconds):
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    h, rest = divmod(round(seconds * 10) / 10, 3600)
    m, s = divmod(rest, 60)
    return f"{sign}{int(h)}:{int(m):02}:{s:04.1f}" if h else f"{sign}{int(m)}:{s:04.1f}"


def pcm_of(path):
    """Any audio file as the show's raw PCM, through ffmpeg."""
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path), "-f", "s16le", "-ar", str(RATE), "-ac", str(CHANNELS), "-"],
        capture_output=True,
    )
    if out.returncode != 0:
        fail(f"ffmpeg couldn't read {path}:\n{out.stderr.decode()[-2000:]}")
    return out.stdout


# --- The program -----------------------------------------------------------


def main():
    args = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    args.add_argument("xlsx", type=Path)
    args.add_argument("tape", type=Path)
    args.add_argument("--date", required=True, help="the trot's date in New York, YYYY-MM-DD")
    args.add_argument("--station-id", type=Path, help="audio for each Break (default: 5 s of silence)")
    args.add_argument("--out", type=Path, help="where to write (default: the spreadsheet's folder)")
    a = args.parse_args()
    out_dir = a.out or a.xlsx.parent

    sheets = read_sheets(a.xlsx)
    if len(sheets) < 2:
        fail(f"{a.xlsx}: expected two sheets (the tape's tracks, then the program), found {len(sheets)}")
    (tape_name, tape_rows), (program_name, program_rows) = sheets[:2]

    tracks = []
    for row in table(tape_rows):
        if not row.get("#"):
            continue
        tracks.append(
            {
                "n": int(float(row["#"])),
                "title": mended(row.get("Song")),
                "artist": artists(row.get("Artist")),
                "duration": sheet_duration(row["Duration"]),
            }
        )
    if [t["n"] for t in tracks] != list(range(1, len(tracks) + 1)):
        fail(f"sheet '{tape_name}': the '#' column should count 1, 2, 3, ... in tape order")

    with wave.open(str(a.tape)) as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (RATE, CHANNELS, WIDTH):
            fail(f"{a.tape}: expected 16-bit stereo at {RATE} Hz")
        tape_frames = w.getnframes()
    length = tape_frames / RATE

    print(f"Finding the gaps between {len(tracks)} tracks on {a.tape.name} ({fmt(length)}) ...", file=sys.stderr)
    starts = boundaries(tracks, silences(a.tape), length)
    for track, start, end in zip(tracks, starts, starts[1:]):
        track["start"], track["end"] = start, end

    # The program's rows, and which starts the trot.
    header = program_rows[0]
    start_letter = next((k for k, v in header.items() if v.strip().startswith("Start")), None)
    if start_letter is None:
        fail(f"sheet '{program_name}': no 'Start' column")
    rows = [row for row in table(program_rows) if row.get("#") not in (None, "")]
    anchor = next((i for i, row in enumerate(rows) if is_zero(row.get(start_letter))), None)
    if anchor is None:
        fail(f"sheet '{program_name}': no row with a {header[start_letter]} of 0 (the one that starts at the trot's start)")
    # Its clock time: in the column after Start.
    clock_letter = chr(ord(start_letter) + 1)
    clock = rows[anchor].get(clock_letter)
    if clock is None:
        fail(f"sheet '{program_name}': the trot's start row has no clock time in column {clock_letter}")
    day = dt.date.fromisoformat(a.date)
    trot_start = dt.datetime.combine(day, dt.time(), NEW_YORK) + dt.timedelta(seconds=round(clock_seconds(clock)))

    station_id = pcm_of(a.station_id) if a.station_id else None
    break_frames = len(station_id) // FRAME if station_id else round(BREAK_S * RATE)

    by_number = {t["n"]: t for t in tracks}
    pieces = []  # (kind, track or None, frames)
    for row in rows:
        n = int(float(row["#"]))
        if n == 0:
            pieces.append({"kind": "break", "artist": artists(row.get("Artist")) or "McTrot radio", "title": mended(row.get("Song")) or "Break", "from": None, "frames": break_frames})
            continue
        if n not in by_number:
            fail(f"sheet '{program_name}': '#' {n} isn't on the tape")
        t = by_number[n]
        if mended(row.get("Song")) != t["title"]:
            print(f"warning: program row #{n} says '{mended(row.get('Song'))}', the tape's #{n} is '{t['title']}'", file=sys.stderr)
        first, last = round(t["start"] * RATE), round(t["end"] * RATE)
        pieces.append({"kind": "track", "artist": t["artist"], "title": t["title"], "from": first, "frames": last - first, "n": n})

    # Offsets in frames from the show's start; the anchor row is at the trot.
    offsets, total = [], 0
    for p in pieces:
        offsets.append(total)
        total += p["frames"]
    show_start = trot_start - dt.timedelta(seconds=offsets[anchor] / RATE)
    show_end = show_start + dt.timedelta(seconds=total / RATE)

    # The render's name: from everything that goes into it.
    key = hashlib.sha256()
    key.update(json.dumps([(p["from"], p["frames"]) for p in pieces]).encode())
    st = a.tape.stat()
    key.update(f"{st.st_size} {st.st_mtime_ns}".encode())
    key.update(hashlib.sha256(station_id or b"").digest())
    show_file = f"show-{key.hexdigest()[:12]}.flac"
    show_path = out_dir / show_file

    if show_path.exists():
        print(f"{show_file} is already made; keeping it.", file=sys.stderr)
    else:
        print(f"Making {show_file} ({fmt(total / RATE)}) ...", file=sys.stderr)
        partial = show_path.with_suffix(".partial.flac")
        encoder = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(RATE), "-ac", str(CHANNELS), "-i", "-",
             "-metadata", "title=McTrot radio", "-c:a", "flac", str(partial)],
            stdin=subprocess.PIPE,
        )
        silence = bytes(break_frames * FRAME)
        with wave.open(str(a.tape)) as w:
            for p in pieces:
                if p["kind"] == "break":
                    encoder.stdin.write(station_id or silence)
                    continue
                w.setpos(p["from"])
                left = p["frames"]
                while left:
                    chunk = w.readframes(min(left, RATE * 10))
                    encoder.stdin.write(chunk)
                    left -= len(chunk) // FRAME
        encoder.stdin.close()
        if encoder.wait() != 0:
            fail("ffmpeg couldn't encode the show")
        partial.rename(show_path)

    def clock_text(moment):
        return moment.astimezone(NEW_YORK).strftime("%-I:%M %p")

    def at(offset_frames):
        return show_start + dt.timedelta(seconds=offset_frames / RATE)

    program = {
        "about": "McTrot radio's program, made by recorder/tools/radio_program.py: the show file, when it starts, and what's on when",
        "file": show_file,
        "startsAt": show_start.timestamp(),
        "endsAt": show_end.timestamp(),
        "startsAtText": show_start.isoformat(),
        "endsAtText": show_end.isoformat(),
        "before": {"artist": "McTrot radio", "title": f"On air at {clock_text(show_start)}"},
        "after": {"artist": "McTrot radio", "title": "Off air"},
        "entries": [
            {
                "offset": offset / RATE,
                "duration": p["frames"] / RATE,
                "artist": p["artist"],
                "title": p["title"],
                "kind": p["kind"],
                "at": at(offset).isoformat(timespec="seconds"),
            }
            for p, offset in zip(pieces, offsets)
        ],
    }
    (out_dir / "program.json").write_text(json.dumps(program, indent=1, ensure_ascii=False) + "\n")

    # The report: the tape's tracks as found, then the schedule.
    print("\nThe tape (sheet duration -> found on the tape):")
    for t in tracks:
        found = t["end"] - t["start"]
        print(f"  #{t['n']:<3} {fmt(t['start']):>9}  {fmt(t['duration']):>7} -> {fmt(found):>7}  {t['artist']} - {t['title']}")
    print(f"\nThe program, {len(pieces)} entries, {clock_text(show_start)} to {clock_text(show_end)} on {day:%A %B %-d}:")
    for p, offset in zip(pieces, offsets):
        mark = "  <- the trot starts" if p is pieces[anchor] else ""
        print(f"  {at(offset).astimezone(NEW_YORK):%-I:%M:%S %p}  {p['artist']} - {p['title']}{mark}")
    print(f"\nWrote {show_path} and {out_dir / 'program.json'}. Upload them (audio first):")
    print(f"  scp {show_path} {out_dir / 'program.json'} root@recorder.mctrot.nyc:/var/lib/mctrot/station/")


if __name__ == "__main__":
    main()

# recorder

The recorder was the temporary server behind McTrot 5 (November 21, 2026):
a bundle of services that ran for the event and was then switched off.
What it recorded is now the replay at
[mctrot.nyc/archive/2026-11-21](https://mctrot.nyc/archive/2026-11-21).

## What it was

One NixOS machine, a DigitalOcean Droplet in New York with an attached
block storage Volume, running:

- **A web API** (TypeScript on Node 26, with Fastify and SQLite): the
  `/live` feed the public page polled, a private posting page for photos,
  videos, voice notes and text from the road (resumable uploads, signed in
  with a passkey), and a worker that encoded the media with `vips` and
  `ffmpeg`.
- **Overland ingest:** the Overland iPhone app sent my GPS fixes in
  batches; check-in taps were matched to McDonald's by those fixes.
- **A Liquidsoap radio station** behind Icecast, playing the day's show on
  schedule, with what was on reported to the page.
- **A minimal social network:** guest accounts signed in with an emailed
  code, to like posts and leave comments (moderated before they showed).
- **Caddy** for HTTPS on `api.`, `radio.` and `media.mctrot.nyc`.

The database and the media lived on the Volume, so the Droplet itself held
nothing that couldn't be rebuilt.

It was deployed from a single Nix flake: `nixos-anywhere` installed NixOS
onto a fresh Droplet (wiping its disk, never the Volume), and every change
after that was `nixos-rebuild switch` against the Droplet, built on the
Droplet itself. Secrets were encrypted in the repo with sops-nix, so only
the machine could read them. DNS was at Namecheap.

The server was last seen running `3cf45f2`. Everything it was made of is
in git: `git checkout 12fa38c -- recorder` brings the whole folder back as
it was before this clean-up, including its design doc (`DESIGN.md`).

## How it went

It worked well. The media encoder had some hiccups and could use more
stress testing and robustness improvements.

It was delightful to have the whole machine in one NixOS configuration (a
single flake), one piece of cloud infrastructure, and only one external
dependency: Mailgun, for sending emails. (The weather came from
Open-Meteo's free API, which needs no account.)

## What's left here

- `export/`: the archive export, `export-archive.ts`, which turns what
  the recorder recorded into the replay's data
  (`website/archive/2026-11-21/archive.json`). Beside it are trimmed copies
  of the server code it reuses, so the replay agrees with what `/live`
  showed. Its ingredients are here too:
  - `recorded.json`: what the recorder recorded (GPS points, check-in taps,
    posts, weather readings, and guests' approved comments and likes),
    dumped from the event's redacted database with only what the export
    reads. No battery, speed or emails.
  - `route-plan.json`: the plan the server used, made from
    `route-plan.gpx` (the simulator's export).
  - `radio-program.json`: the radio's program, what was on when.
  - `skips-2026-11-21.json`: the two McDonald's skipped because they
    weren't open, which the posting page had no button for.

  Run it with the repo's devenv: `export-archive`. It needs only Node 22 or
  later, no packages, and no database.
- The databases, untracked and never committed (`.gitignore`):
  - `recorder-redacted-2026-11-21.sqlite`: the event's database with
    private details removed, which `recorded.json` was dumped from.
  - `prod-2026-11-17.sqlite`, `prod-v4-2026-11-16.sqlite`,
    `prod-v5-2026-11-16.sqlite`: production copies from test walks before
    the event.
  - `dev.sqlite`: local testing.

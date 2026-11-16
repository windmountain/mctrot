# McTrot Live — Design Doc

Nov 15, 2026 · @You

## Overview

During a McTrot attempt, mctrot.nyc/live shows where I am, which McDonald's I've visited, what I'm posting from the road, and a radio station playing alongside — and afterward, the whole day becomes a permanent replay page.

One small NixOS server does all of the live work. The main website stays on Netlify, untouched, and only talks to the server through subdomains.

**Goals**

- Followers can watch a run live: position, track, visit count, posts, radio.
- I can post photos, video, voice notes and text from my phone mid-run, even with bad signal.
- The radio is a real internet station, playable in any radio app, not just on the page.
- One command turns an attempt into static files that outlive the server.

**Non-goals (for now)**

- Other runners streaming their own attempts. It's just me; one hardcoded identity.
- Real-time chat, comments or reactions from followers.
- High availability. One box, carefully tested, is enough for a single event.

**Principles**

- Boring and few: one VM, one database file, no containers, no cloud functions.
- Everything about the server lives in the repo as a Nix flake, so it can be rebuilt from scratch.
- Nothing is lost if the server hiccups: the phone queues location points and posts until they land.
- Privacy by default: only data between an attempt's start and stop is ever public.

## System at a glance

Four subdomains, one server: `mctrot.nyc` stays on Netlify, while `api.`, `radio.` and `media.` all point at a single NixOS VM.

&#91;embedded content: McTrot Live architecture · one VM, four subdomains\]

Data flows left to right: my phone feeds the server, the server feeds the page and the radio listeners, and the archive step copies everything to my laptop afterward.

## Location tracking

My phone runs [Overland](https://github.com/aaronpk/overland-ios), an open-source iOS GPS logger, which posts batches of points to `api.mctrot.nyc/ingest` about every 30 seconds.

**Overland settings**

| Setting | Value |
| --- | --- |
| Receiver endpoint | `https://api.mctrot.nyc/ingest` |
| Access token | the ingest secret (see Secrets) |
| Points per batch | 10 |
| Send interval | 30 s |

Overland expects the reply `{"result":"ok"}`. Until it gets one, it keeps the batch and retries, which is what makes subway tunnels and dead zones harmless.

**API endpoints**

- `POST /ingest` — Overland's batches. Checks the token, stores points, ignores duplicates.
- `POST /attempts/start` and `POST /attempts/stop` — open and close an attempt.
- `GET /live` — everything the page needs in one response: current position, simplified track, visits, posts since a cursor, now playing.

**Data**

One SQLite file. Points are keyed by timestamp, so out-of-order and repeated batches sort themselves out.

```
attempts(id, started_at, ended_at)
points(ts, lat, lon, accuracy, speed, battery, received_at)
visit_taps(id, ts, received_at)
posts(id, attempt_id, ts, type, text, media_path, poster_path, lat, lon, hidden)
jobs(id, post_id, kind, status, error)
weather(fetched_at, forecast_json)
```

Points and visit taps belong to an attempt by time: whatever falls between its start and stop.

**Visits**

A visit counts only when I say so: I tap **Visit** on the upload page at each McDonald's. The tap is just a timestamp, with no location and no store to pick. The server works out which store it was from my GPS track and the store list in the route plan:

1. **Where I was:** my position at the tap's time, interpolated between the GPS points just before and after it.
2. **Which store:** the nearest store within about 150 m of that spot that no earlier tap has claimed. Taps are matched in time order.

Nothing about the match is stored; it's worked out from taps, points and stores each time `/live` is asked. GPS is weakest exactly when I tap (indoors), and Overland may deliver the points around a tap minutes later, so a tap made in a dead zone resolves once those points arrive.

| Case | Result |
| --- | --- |
| No GPS after the tap yet | "Checking in…" until points arrive |
| Two stores close together | The nearest unclaimed store wins, so the next tap goes to its neighbour |
| No store within 150 m | "Unmatched", never forced onto a wrong store |
| Two taps within 2 minutes | One visit |

The 150 m radius and 2-minute window are guesses to tune on a test walk. There's deliberately no manual override.

**Route plan**

The route plan is the simulator's GPX download (/simulator): a waypoint per McDonald's in visiting order, each with a `<mctrot:stop>` extension (mcd_id, address, planned arrival and departure), and a track along the walk. Saved as `recorder/route-plan.gpx`, it's converted to JSON when the system is built (`tools/route_plan.py`), so the API never parses XML; `nix run .#route-plan -- file.gpx` checks one first. Visits are matched against it, and `/live` derives live stats from it (miles done and left, ahead or behind schedule, projected finish) plus the series for the mileage burndown chart.

## Radio

The radio is a real Icecast station at `https://radio.mctrot.nyc/live.mp3`, playing one 10–12 hour audio file with proper artist and title metadata, so it works in VLC, Apple Music's "Open Stream URL", and any radio app.

**How it works**

- **Liquidsoap** plays the long file, encodes it to 128 kbps MP3, and updates artist/title at the right moments from a cue sheet (timestamp → artist, title). Splitting the file into tagged tracks works too.
- **Icecast** serves the stream to listeners. It stays off public directories; the stream link is only shared directly.
- **Caddy** sits in front and provides HTTPS, which the page needs to play the stream at all.

**Scheduled start**

The show starts at a fixed date and time set in the flake, for example `radio.startAt = "2026-12-05T07:00:00-05:00"`. Liquidsoap always plays from the position `now − startAt`, so every listener hears the same moment of the show.

- **Before the start:** a short holding loop plays (a station ID and "on air at…"), so the stream URL is live early for testing.
- **After a restart:** Liquidsoap seeks back to `now − startAt`. A crash costs a gap in the stream, never a drift in the schedule.
- **After the file ends:** the holding loop returns, or the stream goes off air.
- **Changing the time** is a one-line flake change and a deploy. The radio doesn't depend on `POST /attempts/start`, so starting the run a few minutes late doesn't shift the show.

**What gets recorded for the archive**

- An on-air log: every metadata change with its timestamp. If the stream restarts, the replay still matches what people actually heard.
- The broadcast itself, via Liquidsoap's `output.file`, voice-note inserts included.

**Optional: voice notes on air.** Liquidsoap can duck the music and play a voice note I post, with the stream title changed to something like "McTrot — live from 34th St".

**Licensing.** If the file contains other people's music, a public US webcast generally needs licenses (SoundExchange plus the songwriter groups such as ASCAP and BMI). My own audio or cleared mixes need nothing. Worth checking before launch.

**Load.** At 128 kbps a listener uses about 58 MB an hour; 100 listeners for 12 hours is about 70 GB, well inside the server's included bandwidth.

## Posts: photos, video, voice notes, text

I post from a private upload page at `api.mctrot.nyc/post`, saved to my home screen; files resume after dropped signal, get processed on the server, and are served from `media.mctrot.nyc`.

**The upload page**

- Sign-in: a passkey (Face ID) set up once, then a long-lived session cookie. Nobody else can post.
- Two buttons: **Media upload** (one file picker for photos, videos and voice notes; on iPhone it also offers the camera, and voice memos come in through Files) and **Text** (like a tweet, non-rich text).
- Each post records the time it was captured.

**Surviving Manhattan signal**

- Every post is saved to an on-phone outbox (IndexedDB) with its own ID before uploading. The ID stops retries from creating duplicates.
- Uploads use [tus](https://tus.io), a resumable upload protocol: a video that drops at 70% resumes at 70%.
- The outbox shows each post's state: queued, uploading 45%, posted.

**Progress feedback**

Every post shows exactly where it is, from the moment I pick it until it's live, and nothing leaves the outbox until the server confirms it.

| State | What I see | Comes from |
| --- | --- | --- |
| Saving | "Saving…" while the file is copied into the outbox | IndexedDB write |
| Queued | "Waiting for signal" | offline, or behind another upload |
| Uploading | progress bar with %, MB sent, rough time left | tus-js-client progress events |
| Processing | "Processing on server" | job status from the API |
| Live | checkmark, link to the post on /live | post row exists |
| Failed | plain-language reason with Retry and Discard | upload, commit or job error |

- **Outbox list** at the top of the page, newest first, each row with a local thumbnail (from the stored Blob) so I can tell posts apart at a glance.
- **Header summary**: "2 uploading · 1 processing", plus an online/offline dot based on the last successful API call, not just `navigator.onLine`.
- **Home-screen badge** with the pending count (Badging API, supported for home-screen web apps on recent iOS), so I notice unsent posts after switching apps.
- **Errors caught early**: an unsupported or oversized file is flagged right after picking, before it's queued. An expired login asks me to sign in again without touching the outbox.
- **Nothing lost silently**: Discard asks for confirmation; recent posts stay in the list with a quick Hide toggle that sets the post's `hidden` flag.
- The page polls a small status endpoint (`GET /posts?mine&since=…`) every few seconds while anything is processing.

**Processing on the server**

1. The API's built-in tus endpoint (`@tus/server`) receives the file and adds a job when the upload finishes.
2. A low-priority worker (`Nice=19`, `CPUQuota=50%`) processes it so the radio is never starved of CPU:
   - Photos: HEIC to JPEG/WebP, metadata stripped, a \~400 px thumbnail and a \~1600 px full size.
   - Video: 720p H.264 MP4 with `-movflags +faststart`, plus a poster frame.
   - Voice: kept as AAC `.m4a`.
3. Results land in `/var/lib/mctrot/media/{post-id}/`, and the post appears on `/live` at the next poll.

**Serving media**

Caddy serves `media.mctrot.nyc` straight from disk, with range requests for video scrubbing and `Cache-Control: immutable` because file names never change. If a post goes viral, a CDN can go in front of `media.` later without changing any URLs.

**iOS limits to live with**

- Uploads only continue while the page is open. iOS has no background sync for web apps, so a "3 pending" badge reminds me to reopen it.
- Set the camera to 1080p30 for the run and keep clips short; 4K is hundreds of MB a minute.

## The /live page

`/live` is a page on the Netlify site (website/live.html plus an Elm program, a JavaScript exception like simulator.html) that polls `api.mctrot.nyc/live` every 15 seconds and draws everything from that one response.

**What it shows**

- A map (MapLibre or Leaflet) with the track so far, my current position, every McDonald's, and visited ones checked off.
- A header: visits so far out of the total, elapsed time, last update time.
- A feed of posts, newest first, each also pinned on the map where it was taken.
- A radio player: an `<audio>` element on the stream with a custom play button, and now playing (artist, title) from the same poll.
- An off-air state between attempts: last attempt's summary and a link to its replay.

**Why polling.** Overland sends every 30 seconds, so faster updates wouldn't show anything new. Server-Sent Events are an easy upgrade later if posts should appear instantly.

**Why one response.** Browsers can't read the titles embedded in a radio stream, so the API reads Icecast's status over the internal network and folds now-playing into `/live`. One call, one CORS rule, nothing for the page to stitch together.

Media loads as plain `<img>` and `<video preload="metadata" playsinline>` tags pointing at `media.mctrot.nyc`, so Netlify never carries any of it.

## Infrastructure

Everything runs on one DigitalOcean Droplet in the New York region (2–4 GB RAM) running NixOS, described by the flake in recorder/, with no Docker and no Terraform.

**Where it lives in the repo**

Everything server-side sits in one new top-level folder of `windmountain/mctrot`, named for what it is: a recorder that runs for an attempt, leaves a record behind, and gets retired. The public page keeps its name, `/live`.

```
mctrot/
  (existing GIS pipeline: scripts/, data/, notebooks, devenv.nix)
  website/
    live.html            the /live page
    src/Live.elm         its Elm program, built by build.sh
    attempts/<date>/     replay bundles from the archive script
  recorder/
    flake.nix            NixOS config, API package, archive app
    CLAUDE.md            scope and decisions for build sessions
    host/                NixOS modules: caddy, icecast, liquidsoap, api, disks
    api/                 Node 26 TypeScript service
    post/                the upload page, served by the API
    station/             Liquidsoap script and cue-sheet format
    secrets/             sops-encrypted
    route-plan.gpx       the simulator's GPX download
    tools/route_plan.py  turns it into the API's JSON at build time
```

- `recorder/` has its own flake rather than using devenv, so the server deploys without the GIS tooling.
- The radio folder is `station/` because the repo's `.gitignore` ignores `*radio`. The 12-hour audio file stays out of git either way.
- `route-plan.gpx` comes from the simulator's GPX download, which carries every field the recorder needs (see "Route plan").

**Services on the box (all systemd, all from the flake)**

| Service | Role | Source |
| --- | --- | --- |
| Caddy | HTTPS for `api.`, `radio.`, `media.` | `services.caddy` |
| api | ingest, attempts, `/live`, uploads (tus), upload auth, jobs | own package (Node 26 LTS, TypeScript) |
| worker | photo/video processing with ffmpeg and libvips | own unit, low priority |
| Icecast | radio stream | `services.icecast` |
| Liquidsoap | plays the file, metadata, recording | nixpkgs + own unit |

**API stack**

One TypeScript service on Node 26 LTS ("Lithium", supported to April 2029), pinned as `nodejs_26` in the flake and packaged with `buildNpmPackage`.

- **HTTP:** Fastify, with its CORS, cookie and static-file plugins (static files serve the `/post` page).
- **Uploads:** `@tus/server` with `@tus/file-store`, mounted at `/uploads`; finishing an upload queues a job directly, so no separate tusd.
- **Database:** `better-sqlite3`.
- **Passkeys:** `@simplewebauthn/server`, with `@simplewebauthn/browser` on the upload page.
- **Validation:** `zod` schemas for Overland batches and post commits.
- **Media:** the `vips` and `ffmpeg` command-line tools from nixpkgs, called with `execFile`, which avoids native modules like `sharp` that fight Nix's sandboxed builds.
- **Weather:** a timer inside the API fetches the [Open-Meteo](https://open-meteo.com) forecast for Manhattan every 15 minutes (about 100 calls a day; no API key; free for non-commercial use with CC BY 4.0 attribution shown on the page), stores it in the `weather` table, and `/live` includes the latest copy.
- **Shared contract:** `/live` response is described by a JSON Schema in recorder/api/. The API validates against it, and the Elm page's decoder follows it.

**Getting the box up**

1. Create the Droplet, firewall (80/443, plus 22 from my IP), and a DigitalOcean Volume in the console. One-time clicks, noted in the README.
2. Install NixOS onto it with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere), which converts a stock Debian VM over SSH.
3. Deploy changes with `nixos-rebuild switch --flake .#mctrot --target-host root@…`. A bad deploy rolls back to the previous generation.

If I start rebuilding the VM often, a small `bootstrap.sh` (doctl CLI → nixos-anywhere → DNS update) replaces the clicking. Terraform stays out unless that stops being enough.

**DNS (Namecheap, Advanced DNS)**

| Type | Host | Value |
| --- | --- | --- |
| A / ALIAS | `@` | Netlify (unchanged) |
| CNAME | `www` | `yoursite.netlify.app` (unchanged) |
| A | `recorder` | the Droplet's IPv4 address |
| AAAA | `recorder` | the Droplet's IPv6 address (optional) |
| CNAME | `api` | `recorder.mctrot.nyc.` |
| CNAME | `radio` | `recorder.mctrot.nyc.` |
| CNAME | `media` | `recorder.mctrot.nyc.` (later: a CDN hostname) |

The three service names point at `recorder`, so a rebuilt server with a new IP means editing one A record. In Namecheap's Host field, type only the subdomain (`api`), and `@` for the bare domain.

- **TTL:** Automatic is fine; drop it to 5 minutes before the event if a server swap is possible.
- **Order:** create the records before Caddy first starts. It gets certificates by having Let's Encrypt reach these names on port 80.
- **IPv6:** optional, but DigitalOcean includes it free, and the AAAA record serves IPv6-only networks directly.

**Storage**

SQLite and media live on an attached DigitalOcean Volume mounted at `/var/lib/mctrot`, so reinstalling the OS never touches the data. 20–50 GB is plenty.

**Backups**

Volume snapshots in the DigitalOcean console: one before the event and one right after. No object storage. Snapshots can't be downloaded as files (they only restore into a new Volume), so the real off-server copy is the archive step, which downloads everything to my laptop the same day.

**Secrets**

The Overland token and the session-signing secret are encrypted in the repo with `sops-nix` or `agenix`, and only the VM can decrypt them.

## After the event: archive and replay

One command — `nix run .#archive -- --attempt 2026-12-05` — turns an attempt into static files and a permanent replay page at `mctrot.nyc/attempts/<date>/`.

**What the script does**

1. Asks the API for the attempt's data, cut to its start and stop times, with private fields (battery, accuracy) and hidden posts removed.
2. Writes a bundle in a fixed format:
   - `manifest.json` — schema version, start, end, totals.
   - `track.geojson` — thinned to about one point per 10 s; `track-full.geojson.gz` keeps every point.
   - `visits.json` — each visit tap with its time and the store it matched.
   - `posts.json` — every post with time, place, text and media paths.
   - `radio.json` — what actually aired, as offsets from the start.
3. Cuts the broadcast recording into HLS segments (10-second chunks plus a playlist), so jumping to hour 9 is instant.
4. Copies the small JSON into website/attempts/\<date>/ (served at `/attempts/<date>/`), commits and pushes; Netlify builds the page.
5. Copies large files (photos, video, audio) at their existing `media.mctrot.nyc` paths onto a static host, since the Droplet is retired by hand once the export is done.

**Why media stays at the same URLs.** The audio alone is about 700 MB, and GitHub rejects files over 100 MB, so binaries never go in git. Keeping `media.` paths stable means replay pages never need rewriting; retiring the VM is just repointing one DNS record (Bunny Storage works with any DNS).

**End of the event, in order**

1. Take a final Volume snapshot.
2. Run the archive script. Besides the bundle, it downloads a consistent copy of the database (`sqlite3 .backup`), the media folder (`rsync`) and the broadcast recording to my laptop.
3. Check the replay page.
4. Repoint `media.` to the static host and check the replay page still loads its media.
5. Retire the Droplet by hand: delete it and the Volume; keep the last snapshot a while as a safety net.

**The replay page**

One timeline slider drives everything: dragging it moves my position on the map, seeks the audio, fills in the visit count, shows posts up to that moment, and shows the track that was playing.

## Risks, open questions, build plan

The biggest risk is the single server going down mid-run; location and posts survive it, but the radio drops, so a full-length rehearsal matters more than any redundancy.

**Risks**

| Risk | Effect | Mitigation |
| --- | --- | --- |
| VM restarts or crashes | Radio drops; map pauses | Services restart automatically; the radio resumes at its scheduled position; Overland and the outbox queue until it's back |
| Video processing starves the radio | Stream stutters | Worker at `Nice=19`, `CPUQuota=50%` |
| Phone battery dies | Everything stops | Battery pack; Overland battery field shown on a private status view |
| Page closed with uploads pending | Posts arrive late | Pending badge; resume on reopen |
| Visit tap matched wrongly | Wrong or unmatched store | Tune the radius on a test walk; taps carry their time, so late GPS fixes it |
| Forgetting to tap Visit | A store doesn't count (a later tap matches where I am then) | The upload page shows the visit count; tap before leaving |
| A post goes viral | VM bandwidth spike | Cache headers now; CDN in front of `media.` if needed |

**Open questions**

- Which static host keeps the archived media at media.mctrot.nyc once the Droplet is retired (Bunny Storage, DigitalOcean Spaces)?
- Do voice notes go on air, or only on the page?

**Build plan**

Each step adds one layer, stays deployed, and ends with a small demo. Riskiest parts (location, radio scheduling) come early; test attempts run through the real pipeline, with `/live` unlinked until launch.

- [ ] **1. Flake skeleton, local only.** Repo, flake, NixOS config with Caddy in a local VM (`nixos-rebuild build-vm`). Demo: `curl localhost` says hello.
- [x] **2. The real server.** Droplet + Volume, nixos-anywhere, Namecheap DNS, Caddy certificate. Demo: `https://api.mctrot.nyc` says hello.
- [x] **3. API skeleton.** Node 26 package, systemd unit, SQLite on the Volume, sops-nix secrets. Demo: `GET /health` shows version, database and uptime; a deploy changes the version.
- [x] **4. Location ingest.** `POST /ingest` with token. Demo: Overland on a walk around the block; `GET /debug/points?last=10`.
- [ ] **5. First `/live`.** Last position in JSON; bare Netlify page with a dot on a map. Demo: refresh during a walk.
- [ ] **6. Attempts, route plan, visits.** Attempts start/stop, the route plan's store list, `POST /visits` taps (by curl until step 9) matched to stores by GPS. Demo: a fake three-stop route of nearby coffee shops; a tap at each, and the visit count goes up.
- [ ] **7. Radio, part 1.** Icecast + Liquidsoap on a test loop with a fixed title. Demo: VLC plays `radio.mctrot.nyc/live.mp3`.
- [ ] **8. Radio, part 2.** Scheduled start, cue sheet, on-air log, now-playing in `/live`. Demo: 10-minute file with four cues starting in five minutes; titles change on time; a restart resumes at the right spot.
- [ ] **9. Posting, part 1.** Passkey sign-in, text-only posts, and the **Visit** button. Demo: "hello" from the phone shows in `/live`.
- [ ] **10. Posting, part 2.** tus uploads and photo processing, then video and voice. Demo: a photo appears with its thumbnail.
- [ ] **11. Outbox and progress.** Demo: three posts in airplane mode land after reconnecting.
- [ ] **12. Weather, stats, burndown data.** Demo: `/live` shows the forecast and miles walked on the test route.
- [ ] **13. Archive.** Demo: a replay page for the walk-around-the-block attempt.
- [ ] **14. Restore drill.** Demo: a snapshot restored onto a fresh Droplet brings everything back.
- [ ] **15. Dress rehearsal.** A full 12-hour run the week before.

**Human tasks**

- [ ] Record the 10–12 hour radio file
- [ ] Prepare the cue sheet (timestamp → artist, title) for the radio file
- [ ] Prepare the route plan: set the start time, pace and stop length in /simulator, download its GPX as `recorder/route-plan.gpx`, and set `recorder.routePlan` in `host/configuration.nix`
- [ ] Pick the event date and the radio start time
- [ ] Configure start time (`radio.startAt` in the flake)
- [ ] Before going live, set `recorder.live = true` in `recorder/host/configuration.nix` and deploy: it blocks `nix run .#wipe` and `nix run .#dislocate` and stops a schema change from setting event data aside
- [ ] Check music licensing for the radio file
- [x] Create the DigitalOcean Droplet and Volume
- [x] Add the DNS records at Namecheap
- [ ] Set up Overland on the phone and register the passkey on the upload page
- [ ] Set the iPhone camera to 1080p30 before the run

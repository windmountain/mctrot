# recorder

The ephemeral server behind [mctrot.nyc/live](https://mctrot.nyc/live):
location tracking, posts from the road, and the radio station during a
McTrot attempt, then an archive for the website afterward.

Everything about the machine is in this folder's Nix flake. See
`CLAUDE.md` for the decisions and conventions, and the design doc linked
there for the full picture.

## Try it locally

```
cd recorder
nix run .#vm          # boots the recorder in QEMU
curl localhost:8080   # in another terminal: "hello from mctrot (local VM)"
```

The VM's console login is `root` / `recorder` (local VM only). Quit QEMU
with `Ctrl-a x`.

## The real server (step 2)

The flake describes the Droplet completely; these are the only clicks
outside it. Do them once, in this order.

**1. DigitalOcean console**

- **Droplet:** region NYC (any NYC datacenter), image Ubuntu 24.04 or
  Debian 12 (it gets replaced), 2–4 GB RAM (nixos-anywhere needs at least
  ~1.5 GB to switch kernels), IPv6 on, authentication: SSH key
  `zach@windmountainsoftware.com` (`~/.ssh/id_ed25519.pub`). Name it
  `recorder`.
- **Volume:** 20–50 GB, same datacenter, attached to the Droplet, name
  exactly `recorder-data`, "Automatically Format & Mount", ext4. The name
  is baked into `host/digitalocean.nix` as
  `/dev/disk/by-id/scsi-0DO_Volume_recorder-data`.
- **Cloud Firewall** on the Droplet: inbound TCP 80 and 443 from anywhere,
  TCP 22 from my IP only. Outbound: everything.

**2. Namecheap, Advanced DNS** (before Caddy first starts, so Let's
Encrypt can reach the names on port 80)

| Type | Host | Value |
| --- | --- | --- |
| A | `recorder` | the Droplet's IPv4 |
| AAAA | `recorder` | the Droplet's IPv6 (optional) |
| CNAME | `api` | `recorder.mctrot.nyc.` |
| CNAME | `radio` | `recorder.mctrot.nyc.` |
| CNAME | `media` | `recorder.mctrot.nyc.` |

Check with `dig +short api.mctrot.nyc` before installing.

**3. Install NixOS** (wipes the Droplet's own disk; the Volume isn't
touched because it's not in `host/disko.nix`)

```
cd recorder
nix run .#install -- <droplet-ipv4>
```

Builds on the Droplet, so no Linux builder is needed on the Mac. The box
reboots into NixOS; the old host key is gone, so drop it with
`ssh-keygen -R <droplet-ipv4>`.

**4. Demo**

```
curl https://api.mctrot.nyc          # hello from mctrot
ssh root@recorder.mctrot.nyc df -h /var/lib/mctrot   # the Volume
```

**Later changes:** `nix run .#deploy` (defaults to
`root@recorder.mctrot.nyc`; pass another `user@host` to override). A bad
deploy rolls back with `nixos-rebuild switch --rollback` on the box, or by
picking the previous generation in the GRUB menu from the Droplet console.

## The API (step 3)

`api/` is a Node 26 TypeScript service (Fastify, better-sqlite3). Node runs
the `.ts` files directly; `tsc` only type-checks. On the box it runs as
`mctrot-api.service` (user `mctrot`) behind Caddy at `api.mctrot.nyc`, with
its database at `/var/lib/mctrot/db/recorder.sqlite` on the Volume.

```
curl https://api.mctrot.nyc/health   # version = git commit, database, secrets
```

**Working on it locally**

```
cd recorder/api
nix develop ..          # Node 26, sops, ssh-to-age
npm install
npm test && npx tsc     # tests and type-check
npm run dev             # http://localhost:3000/health
```

`nix build .#api` (from `recorder/`) builds the same package the server
runs, tests included.

**After changing dependencies** (`package-lock.json`), update
`npmDepsHash` in `api/package.nix`:

```
nix run --inputs-from . nixpkgs-darwin#prefetch-npm-deps -- api/package-lock.json
```

(If you forget, the build fails with a hash mismatch showing the right
value.) npm blocks dependency install scripts by default; native packages
need `npm install-scripts approve <pkg>`, and their build in
`package.nix`.

**Logs:** `ssh root@recorder.mctrot.nyc journalctl -u mctrot-api -f`

## Secrets

Secrets live encrypted in `secrets/recorder.yaml`, readable by my SSH key
(`~/.ssh/id_ed25519`) and the Droplet's SSH host key (see `.sops.yaml`).
The box decrypts them at boot into `/run/secrets/`; services get them as
systemd credentials.

```
cd recorder
nix develop
sops secrets/recorder.yaml                                   # edit
sops decrypt --extract '["ingest-token"]' secrets/recorder.yaml   # read one
```

A new secret also needs an entry in `host/secrets.nix` and a
`LoadCredential` line on the service that uses it.

**After reinstalling the Droplet** its host key changes, so it can no
longer decrypt. Get the new key and re-encrypt:

```
ssh-keyscan -t ed25519 recorder.mctrot.nyc | cut -d' ' -f2- | ssh-to-age
# put the result in .sops.yaml as &recorder, then:
sops updatekeys secrets/recorder.yaml
```

## Location (step 4)

My phone runs [Overland](https://github.com/aaronpk/overland-ios), which
posts batches of GPS points to `POST /ingest`. Points are keyed by the
phone's timestamp, so retried and late batches never store anything twice.

**Overland settings**

| Setting | Value |
| --- | --- |
| Receiver endpoint | `https://api.mctrot.nyc/ingest` |
| Access token | `sops decrypt --extract '["ingest-token"]' secrets/recorder.yaml` |
| Points per batch | 10 |
| Send interval | 30 s |

Overland never shows an error for a wrong token or a down server: it
keeps the batch and retries. **If its queue count keeps growing, check the
token and `/health`.** Nothing is lost; the queue uploads once fixed.

**Checking what arrived** (the token guards it: it's my location)

```
TOKEN=$(sops decrypt --extract '["ingest-token"]' secrets/recorder.yaml)
curl -s "https://api.mctrot.nyc/debug/points?last=10" -H "Authorization: Bearer $TOKEN"
ssh root@recorder.mctrot.nyc journalctl -u mctrot-api -f | grep ingest   # stored/duplicates/skipped per batch
```

## Data: schema changes, wiping, going live

Everything the recorder records lives on the Volume under
`/var/lib/mctrot`. There are no migrations: the schema is
`api/src/schema.ts`, and when `SCHEMA_VERSION` changes the API moves the
old database aside as a dated `.bak` and starts empty.

**Back to fresh out of the box:**

```
nix run .#wipe
```

Lists what's on the Volume, asks you to type `wipe`, stops the services
that use it, empties it, and starts them again. Config, secrets, SSH keys
and HTTPS certificates are untouched. Overland's queue on the phone isn't:
anything still waiting there uploads after the wipe.

**Making a test walk look like Manhattan:**

```
nix run .#dislocate
```

Moves every recorded point so the walk is centered on Union Square
(40.735556, -73.990556), keeping its shape and distances. It shows the
point count, where the walk is now and how far it would move, asks you to
type `dislocate`, then stops the API, moves the points in one transaction
and starts the API again (even if the move fails). Overland queues
meanwhile. Running it twice moves nothing the second time. Points that
arrive afterwards, including Overland's queue, land where they were really
recorded.

**Before the event:** set `recorder.live = true` in
`host/configuration.nix` and deploy. Then `wipe` and `dislocate` refuse,
and a schema change stops the API instead of setting the database aside.

## /live (step 5)

`GET https://api.mctrot.nyc/live` is public (any origin, never cached):
the latest point, and the server's clock so the page can show how old it
is. Its shape is `api/src/live.ts`; `api/live.schema.json` is generated
from it with `npm run schema` (a test fails when it's stale), and
`website/src/Live.elm`'s decoder follows it.

The page is `website/live.html` + `website/src/Live.elm`, built into
`website/build/` by `website/build.sh` like the rest of the site, and
unlinked (`noindex`) until launch. It draws on the simulator's Manhattan
map: `website/src/Projection.elm` turns latitude/longitude into that
map's coordinates (EPSG:2263, rotated 29°), and `ProjectionTest` checks
every McDonald's lands on its dot.

To try the page against a local API:

```
cd recorder/api && nix develop .. -c npm run dev     # API on :3000
open "website/build/live.html"                        # or any static server, then:
# http://localhost:<port>/live.html?api=http://localhost:3000
```

## Attempts and visits (step 6)

> **Attempts are set aside for now** (`USE_ATTEMPTS = false` in
> `api/src/live.ts`): `/live` matches every check-in to a store and draws
> every recorded GPS point as the walked path, attempt or not. Starting and
> stopping attempts still works and `/live` still reports the latest; set
> `USE_ATTEMPTS` back to true to limit check-ins and the path to it.

An attempt is a start and a stop time; `/live` shows the running attempt
(or the last one), and only Visit taps inside it count. A **Visit tap** is
only a time: the API matches it to the nearest unclaimed store within
150 m of where my GPS says I was (DESIGN.md, "Visits"). Until the upload
page's Visit button (step 9), use curl, with the ingest token:

```
TOKEN=$(sops decrypt --extract '["ingest-token"]' secrets/recorder.yaml)
api() { curl -s -X POST "https://api.mctrot.nyc$1" -H "Authorization: Bearer $TOKEN"; echo; }
api /attempts/start
api /visits              # "I'm here", now
api /attempts/stop
curl -s https://api.mctrot.nyc/live    # attempt, stores, visits
```

**The route plan** is a GPX: the simulator's GPX download, saved as
`route-plan.gpx` here. Each waypoint carries a `<mctrot:stop>` extension
(mcd_id, address, planned arrive/depart) that other GPX apps ignore.
Point `recorder.routePlan` at it in `host/configuration.nix` and deploy;
the build converts it to the JSON the API reads (`tools/route_plan.py`).
Without a route plan, the API has no stores and no tap can match.

```
nix run .#route-plan -- route-plan.gpx   # check it first: the JSON the API would get
```

**A test walk with your own stores:** hand-write a GPX with a waypoint
per store and point `recorder.routePlan` at it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="by hand" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="40.7362" lon="-73.9903"><name>Coffee 1</name><desc>10 Union Sq E</desc></wpt>
  <wpt lat="40.7381" lon="-73.9881"><name>Coffee 2</name></wpt>
</gpx>
```

Without `<mctrot:stop>`, a waypoint's id is its position in the file and
its address is its `<desc>` (the converter warns). The `/live` page draws
whatever stores the plan has; ones outside Manhattan are off its map,
but the visit count still works.

## The upload page (posting from the road)

`https://api.mctrot.nyc/post`, served by the API from `post/` (plain HTML
and JS, no build step). Three buttons: **Visit** (a visit tap), **Post**
(text), **Upload** (photos and video; not yet).

**Setting up a phone, once:**

1. Open `https://api.mctrot.nyc/post`, open "Use the ingest token
   instead", and paste the token
   (`sops decrypt --extract '["ingest-token"]' secrets/recorder.yaml`).
2. Tap **Add Face ID to this phone**.
3. Share → **Add to Home Screen**.

From then on, **Sign in with Face ID**; a session lasts 180 days. The
token always works as a fallback.

**The outbox:** every tap goes into IndexedDB on the phone first, with its
own id and the time I tapped, and is sent from there until the server
confirms it: on every tap, on reopening the page, on coming back online,
and every 5 s. Each item shows *Waiting for signal*, *Sending…*,
*Uploading 45% · 12 of 26 MB*, *Processing on server*, *Sent ✓* or
*Failed* (with Retry and Discard), and the home-screen icon shows a badge
with what hasn't reached the server. Being signed out never loses
anything; it waits until you sign in again. Visits and text posts send in
their own lane, so a long video upload never holds them up. Uploads only
happen while the page is open (iOS has no background sync for web apps).

## Uploads: photos, video, voice (step 10)

**Upload** takes a photo, video or voice note (on iPhone: the camera,
Photos or Files), up to 1 GiB. Files go over tus (`/uploads`), so a
dropped upload resumes where it stopped, even after reopening the page.
A finished upload becomes a *processing* post and a job; the **worker**
(`mctrot-worker`, `api/src/worker.ts`) takes jobs one at a time, at low
priority (`Nice=19`, half a CPU, idle I/O) so it can't starve the radio:

| Upload | Becomes | With |
| --- | --- | --- |
| Photo (HEIC, JPEG, …) | `full.jpg`, ~1600 px long side | `thumb.jpg`, ~400 px |
| Video | `video.mp4`, H.264, 720p short side, plays while loading | `poster.jpg` |
| Voice note | `voice.m4a`, AAC | |

All metadata is stripped (a photo's EXIF holds where it was taken), and
photos are turned upright. Results go to `/var/lib/mctrot/media/<post id>/`,
served by Caddy at `https://media.mctrot.nyc/<post id>/…` with permanent
caching; `/live` shows a post once it's processed. A file that fails
three times shows *Failed* with the reason on the page.

```
ssh root@recorder.mctrot.nyc journalctl -u mctrot-worker -f   # what the worker is doing
```

iPhone HEIC photos are grids of ~48 tiles, which libheif refuses by
default (more than 16); the worker lifts that limit for HEIF, since only
I can upload. `api/test/fixtures/tiled.heic` (20 tiles) keeps it tested.

**Secrets:** the session cookie is signed with `session-secret` in
`secrets/recorder.yaml`; passkeys are stored in the database (so `wipe`
removes them: set up Face ID again after a wipe).

### DoubleTake pairs

DoubleTake films the back camera (A) and front camera (B) at once and saves
two videos, `…_A.MOV` and `…_B.MOV`. Upload both, in either order; the
worker pairs any two videos with the same time and length (within 0.1 s)
into one post (`api/src/pairs.ts`), keeping only the A/B letter from the
filenames. It makes two cuts that switch cameras halfway, `ab.mp4` and
`ba.mp4`. A pair starts as AB; switch it on the upload page. Phones see the
cut; wide screens see both clips side by side in one player
(`website/js/pair-player.js`). A DoubleTake clip waits up to 10 minutes for
its partner before showing on its own.

## Weather and sun (step 12)

`mctrot-weather` fetches the current weather for central Manhattan
(40.7831, −73.9712, Central Park near 81st St) from
[Open-Meteo](https://open-meteo.com) every 10 minutes and saves each
reading in the `weather` table (`api/src/weather.ts`). No account or key.
`/live` shows the latest.

Sunrise, sunset, solar noon and civil, nautical and astronomical twilight
for today in New York are calculated from the date and that point
(`api/src/sun.ts`, NOAA's formulas; within a minute of published tables).

```sh
ssh root@recorder.mctrot.nyc systemctl list-timers mctrot-weather   # next run
ssh root@recorder.mctrot.nyc journalctl -u mctrot-weather -n 5      # last fetches
curl -s https://api.mctrot.nyc/live | jq '.weather, .sun'
```

### The sky's colour

`/live` shows the sky's colour overhead and low (10° up) to the NE, NW, SE
and SW, as tiles (a column pinned bottom-left on wide screens), simulated
by `api/src/sky.ts` from the
sun's position and the latest weather: sunlight scattered once through
the air (Rayleigh for blue, Mie for haze from the reported visibility,
ozone for twilight's blue), blended toward a grey or sunset-lit cloud deck
by cloud cover, plus Manhattan's glow at night, shown as an eye adapted to
the light would see it. Worked out at most once a minute. A plausible sky,
not a photograph: deep twilight comes out darker than it really is, and
broken cloud is averaged.

## Radio (step 7)

`https://radio.mctrot.nyc/live.mp3` is a real internet radio station: open
it in VLC, Apple Music ("Open Stream URL") or any radio app, or press play
on `/live`. For now it plays a 30-second 440 Hz test tone on loop, titled
"McTrot - Test tone" (`station/test-loop.liq`); step 8 replaces it with
the scheduled show.

For players that want a playlist link rather than the stream itself,
`https://radio.mctrot.nyc/live.m3u` and `/live.pls` point at it (browsers
need the stream). `https://radio.mctrot.nyc/` (and `http://`, which
redirects) is a small page listing all three.

- **Liquidsoap** (`mctrot-radio`) loops the tone, encodes 128 kbps stereo
  MP3 and sends it to Icecast. Its first start after a Liquidsoap upgrade
  takes about 20 seconds (it type-checks its whole library on one CPU);
  after that a cache in `/var/cache/mctrot-radio` makes restarts quick.
- **Icecast** (`icecast`) serves listeners, on 127.0.0.1 only. Caddy
  passes on `/live.mp3` and nothing else, so Icecast's admin pages aren't
  reachable from outside. Not listed in any public directory.
- Its passwords (`icecast-source`, `icecast-admin`) are sops secrets,
  filled into Icecast's config when the box starts (sops-nix templates),
  never in the Nix store.

```sh
curl -sI https://radio.mctrot.nyc/live.mp3 | head -5     # 200, audio/mpeg
ssh root@recorder.mctrot.nyc journalctl -u mctrot-radio -n 20 --no-pager
ssh root@recorder.mctrot.nyc 'curl -s localhost:8000/status-json.xsl'   # listeners, title
```

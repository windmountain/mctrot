# /live redesign: mobile

The design for `/live` (`live.html`, `src/Live.elm`, `src/Radio.elm`,
`src/Guests.elm`, `js/pair-player.js`), worked out in ASCII wireframes on
2026-11-20. Mobile first: everything here is for a phone (~390 px wide).
Desktop comes later.

The aim is less visual noise, not a new look. It borrows ideas from IBM's
Carbon design system (a grid, a spacing scale, a few named text styles,
square shapes, its icons) but keeps the site's own Helvetica stack and
identity. No IBM Plex.

Each view has a different way of moving, on purpose:

| View     | Moves by                                         |
|----------|--------------------------------------------------|
| Overview | scrolls vertically, like a page                  |
| Map      | zooms in fixed steps, pans inside its frame      |
| Blog     | scrolls vertically, newest first                 |
| Timeline | scrolls horizontally, one hour per step          |
| Stats    | tiles that fill the screen; one maximizes        |

## The frame (every view)

```
┌──────────────────────────────────┐
│ McTROT 5              Sign out   │  ← pinned
│ [ Map ][ Blog ][ Timeline ][Stats]│  ← pinned
├──────────────────────────────────┤
│                                  │
│            the view              │
│                                  │
├──────────────────────────────────┤
│▶ RADIO · OFF               LINKS │  ← pinned
└──────────────────────────────────┘
```

- **Title row**: "McTROT 5" at the left. "Sign out" at the right only when
  a guest is signed in (it replaces today's "Signed in as … · Sign out"
  line above the posts; no name shown).
- **No tagline** on /live.
- **Tabs**: Map, Blog, Timeline, Stats. Square, not a pill. The title
  goes to the overview, as now.
- Both the title row and the tabs stay pinned while the view scrolls.
- **Radio stripe**, pinned to the bottom of the screen, above the iPhone's
  home indicator (`env(safe-area-inset-bottom)`):
  - One line, ~32 px visible, its tap area extended to 44 px.
  - Full width, all-caps `heading` text. Yellow (`--accent`) for now.
  - Play/stop at the left; the whole left side starts and stops it.
    Off: "RADIO · OFF". Playing: "NOW: {title} — {artist}", cut with "…",
    never scrolling like a ticker.
  - "LINKS" at the right; its panel opens upward.
  - Volume slider just left of Links where volume is adjustable (not on
    iPhone/iPad, as now).
  - Views that scroll get bottom padding so the stripe never covers the
    last thing on them.

## Overview (`/live`)

The status paragraph, and nothing below it.

```
├──────────────────────────────────┤
│ Zach Rose's annual challenge to  │
│ eat at every McDonald's in       │
│ Manhattan, on foot, in one go.   │
│ The goal for this year is 10     │
│ hours. 22 of 46 visited, 24 to   │
│ go, 4 hours 12 minutes in and 9  │
│ minutes behind plan. Overcast,   │
│ 47°F. "Wind tunnel on 6th. Hat   │
│ gone." posted 3 minutes ago. On  │
│ McTrot Radio: Mr. Blue Sky by    │
│ Electric Light Orchestra.        │
│                                  │
├──────────────────────────────────┤
│▶ RADIO · OFF               LINKS │
└──────────────────────────────────┘
```

### The paragraph

Robotic and factual. No editorializing about the weather. No store
nicknames (SLOPER, PUNCH, …) anywhere in it.

Built from parts, in this order, leaving out any part with nothing to say:

1. **Opener**, always: "Zach Rose's annual challenge to eat at every
   McDonald's in Manhattan, on foot, in one go. The goal for this year is
   10 hours." ("was" once finished.)
2. **Progress**, by phase:
   - Before the start: "The route will cover {miles} miles. Beginning
     {countdown} at {start address}."
     - More than a day out: "Beginning Saturday, November 21 at 5:05 AM at …"
     - Under a day: "Beginning in 7 hours 52 minutes at …"
     - Under an hour: "Beginning in 14 minutes at …"
     - Past the planned start, no visit yet: "Beginning any minute now at …"
     - Start address: the first store's address (608 West 207th Street).
     - Miles: 26.7, the simulator's figure for the planned route.
   - During: "{visited} of 46 visited, {remaining} to go, {elapsed} in and
     {n} minutes ahead/behind plan."
   - Finished: "Done: all 46 in {time}."
3. **Light**, only when it isn't plain daylight:
   - "Dark, 47 minutes until astronomical twilight."
   - "Nautical twilight, 18 minutes until civil twilight."
   - "Civil twilight, 12 minutes until sunrise."
   - Within 15 minutes of an event: "Sunrise 6 minutes ago.",
     "Solar noon in 6 minutes.", "Sunset in 9 minutes."
   - Evening: "Civil twilight, 20 minutes until nautical twilight."
   - (From `SolarTime.elm`'s data; the 15-minute window is to be tuned.)
4. **Weather**: sky and temperature always ("Overcast, 47°F."). Feels-like
   only when 5°F or more off ("Clear, 38°F, feels like 31°F."). Wind only
   at 10 mph or more, with gusts if reported ("Light rain, 44°F, wind NW
   14 mph, gusts 22.").
5. **Latest post**, if under about an hour old: a text post quoted, cut at
   ~80 characters with "…" ("'Wind tunnel on 6th. Hat gone.' posted 3
   minutes ago."); otherwise "A photo / video / voice note posted N
   minutes ago."
6. **Radio**: "On McTrot Radio: {title} by {artist}." Left out when
   nothing's playing.

The plan runs 5:05 AM to 2:49 PM (9 h 44 min), inside the 10-hour goal.

## Map (`/live/map`)

```
├──────────────────────────────────┤
│┌────────────────────────┐   (+)  │
││ 9:16 PM · 14 min ago   │   (−)  │
│└────────────────────────┘        │
│      ⚑                           │
│       ●                          │
│       ●──●                       │
│          │      ●──●             │
│          ●──●   │                │
│             ●───●                │
│                 ▪ ┌───────────┐  │
│                 ● │ UNION     │  │
│                   │ Open 24 h │  │
│                   └───────────┘  │
│       ●──●──●                    │
├──────────────────────────────────┤
│▶ RADIO · OFF               LINKS │
└──────────────────────────────────┘
```

- The map fills the space between the tabs and the radio stripe. The page
  doesn't scroll; dragging and zooming move only the map.
- The last-position line becomes a chip floating at the top left.
- Zoom buttons float at the top right.
- Tapping a dot opens its box, as now. (The map's own labels, like store
  names in these boxes, are not the overview paragraph; nicknames are fine
  here.)

### Centering at the edges

Today the map can't center a dot near its edge (e.g. far-north SLOPER):
the frame can't scroll past the drawing. When zoomed in, the drawing gets
an empty margin of half the frame on each side (half its width left and
right, half its height above and below), so any point can reach the
middle. At zoom 1 there's no margin: the island just fits the frame.

### Zooming

Zoom steps stay as they are: 1×, 2×, 4×, 8×, 16× (`maxZoom`).

- **+ / −** buttons: one step, as now.
- **Pinch**: pure steps, no live preview. Fingers spread past ×1.5 of
  their starting distance → one step in (`Zoom 2`); pinched below ÷1.5 →
  one step out. The starting distance resets after each step, so one long
  pinch can take several steps. The threshold is to be tuned on a phone.
- **Double-tap**: one step in, at the tap point.
- Pinch and double-tap zoom around the point under the fingers, which
  stays put: a new message beside `Zoom`, e.g. `ZoomAt by point`.
- The map keeps `touch-action: pan-x pan-y` so the page itself never
  zooms. Check on an iPhone with the accessibility zoom override on.

## Blog (`/live/blog`)

```
├──────────────────────────────────┤
│                                  │
│ 10:42 AM                         │
│ ┌──────────────────────────────┐ │
│ │                              │ │
│ │          [ photo ]           │ │
│ │                              │ │
│ └──────────────────────────────┘ │
│ ♥                                │
│   Ana  this is the one           │
│   Ben  go go go                  │
│   More comments                  │
│   Add a comment…                 │
│                                  │
│ ──────────────────────────────── │
│ 10:31 AM                         │
│ Stopped for a minute. My feet    │
│ are fine. My feet are not fine.  │
│ ♡                                │
│                                  │
│ ──────────────────────────────── │
│ 10:20 AM                         │
│ ┌──────────────────────────────┐ │
│ │ ▶  ━━━━━━━━━━━━━━━━━  0:42   │ │
│ └──────────────────────────────┘ │
│ ♡                                │
├──────────────────────────────────┤
│▶ RADIO · OFF               LINKS │
└──────────────────────────────────┘
```

- Newest first.
- Each post: its time on top (time only, no date), then the post, then the
  like icon, then the latest one or two comments, "More comments" if
  there are more, and "Add a comment…". No comment icon: "Add a
  comment…" is always there.
- **No counts.** Likes are never counted or shown as numbers; the heart
  only shows whether you liked it. "More comments" has no number either.
- No "near {store}" and no link to the post's pin on the map.
- "Starting November 21, …" is gone from here (the overview says it).
- **DoubleTake pairs**: on a phone, the edited cut only. On wide screens,
  both clips side by side with one set of controls. `js/pair-player.js`
  already does this at `min-width: 48rem`. Add: also show the cut when the
  browser reports Data Saver (`navigator.connection.saveData`).

## Timeline (`/live/timeline`)

```
├──────────────────────────────────┤
│                                  │
│ 46┆    7 AM    ┆    8 AM    ┆   9│
│   ┆            ┆            ┆    │
│ 40━┓           ┆            ┆    │
│   ┆┗━┓  ●      ┆            ┆    │
│   ┆  ┗━━┓      ┆            ┆    │
│ 30┆     ┗━┓    ┆            ┆    │
│   ┆       ┗━━┓ ┃ now        ┆    │
│   ┆          ┗━┓            ┆    │
│ 20┆            ┗━━┓         ┆    │
│   ┆               ┗━┓       ┆    │
│ 10┆                 ┗━━┓    ┆    │
│   ┆                    ┗━┓  ┆    │
│  0┆                      ┗━━┆━━━ │
│                                  │
│ ▕░░░░░▓▓▓▓▓░░░░░░░░░░░░░░░░░░░▏  │
│  5AM          12PM          3PM  │
├──────────────────────────────────┤
│▶ RADIO · OFF               LINKS │
└──────────────────────────────────┘
```

The burndown chart (`src/Burndown.elm`), horizontal and scrolling.

- Time runs across; McDonald's to go runs 46 at the top to 0 at the
  bottom. Plan in grey, actual in red, each stepping down as McDonald's
  are done.
- **Stops every hour.** About three hours on screen. CSS scroll snapping
  with `scroll-snap-stop: always`, so a swipe moves exactly one hour. On
  desktop, a grab-and-drag hand that settles on the nearest hour, and the
  arrow keys step. No zooming.
- Hour labels along the top. The 46 → 0 axis stays fixed at the left
  while the chart slides under it.
- Opens with "now" about a third of the way in from the left.
- **Day strip** at the bottom: the whole day, small, with the visible part
  highlighted. Tap or drag it to jump.
- **Post dots** stay: on the red line at the moment of posting (no more
  latitude axis), tapping one opens its box, as now.
- The summary line ("44 to go. Starts …") moves to the overview.

## Stats (`/live/stats`)

```
├────────────────┬─────────────────┤
│ PROGRESS     ⤢ │ PACE          ⤢ │
│                │                 │
│   2 / 46       │   +36 min       │
│                │   ahead         │
├────────────────┴─────────────────┤
│ WEATHER                        ⤢ │
│ 45°F overcast · feels 38°        │
│ Wind SW 6, gusts 11              │
│ ▪Z  ▪NW  ▪NE  ▪SE  ▪SW           │
├──────────────────────────────────┤
│ SUN                            ⤢ │
│ ☀ 6:48 AM ───────────── 4:33 PM  │
├──────────────────────────────────┤
│ PLAN                           ⤢ │
│ SHORTY III   9:51   +36          │
│ MICHAELS    10:00                │
│ OVERLAND    10:09                │
├──────────────────────────────────┤
│▶ RADIO · OFF               LINKS │
└──────────────────────────────────┘
```

A grid of tiles filling the frame, like windows. The page doesn't scroll.

- Tapping a tile (or its maximize icon) makes it fill the frame; its
  restore icon or title puts it back. Only a maximized tile scrolls.
- **PROGRESS**: visited / total, as a `display` number.
- **PACE**: minutes ahead or behind plan.
- **WEATHER**: the weather, with the sky folded in as very small swatches
  (~12 px) labeled Z, NW, NE, SE, SW. Maximized, the swatches can be
  larger, with when the sky was read.
- **SUN**: one bar from sunrise to sunset. Maximized: the twilight table.
- **PLAN**: the next few stops, taking whatever height is left.
  Maximized:

  ```
  │ PLAN                           ⤡ │
  ├──────────────────────────────────┤
  │   SLOPER          5:05   5:02 −3 │
  │   608 W 207th St                 │
  │   STRADDLER       5:14   5:20 +6 │
  │   208 Dyckman St                 │
  │ ▸ CHAMFER         5:36           │
  │   4259 Broadway                  │
  ```

  Two lines per stop: nickname, planned, actual, difference; the address
  small beneath. The next stop is marked.
- PROGRESS and PACE repeat what the overview says; that's fine.

## Design tokens

CSS variables in `css/style.css`. /live uses only these.

### Text styles

| Name      | Size / line | Weight                    | For                                         |
|-----------|-------------|---------------------------|---------------------------------------------|
| `display` | 32 / 32     | bold, −0.02em             | "McTROT 5", big numbers (2 / 46, +36 min)   |
| `heading` | 12 / 16     | bold, caps, +0.08em       | tile labels, the radio stripe               |
| `body`    | 17 / 26     | regular                   | the paragraph, posts, comments              |
| `ui`      | 15 / 20     | bold                      | tabs, buttons, Sign out, names in tables    |
| `helper`  | 13 / 18     | regular, `--ink-muted`    | times, axis labels, addresses               |

Five to start, replacing about 25 sizes in use today. Add a sixth only if
one is clearly missing (a likely candidate: a title for a maximized tile).

### Spacing

| Variable    | px | For                                   |
|-------------|----|---------------------------------------|
| `--space-1` |  4 | inside a control (icon ↔ label)       |
| `--space-2` |  8 | related lines (time ↔ post)           |
| `--space-3` | 12 | inside tiles and the stripe           |
| `--space-4` | 16 | page side margins                     |
| `--space-5` | 24 | between posts, between sections       |
| `--space-6` | 32 | above a major break                   |
| `--space-7` | 48 | rarely: top of empty states           |

### Lines and shapes

- Hairline: 1 px `--line`: dividers between posts, table rows, gridlines.
- Strong: 2 px `--ink`: control borders, tile edges, under the tabs.
- Corner radius 0 everywhere. The tabs become square.

### Colors

Named by role, so the palette can change in one place later.

| Variable      | Value     | For                                            |
|---------------|-----------|------------------------------------------------|
| `--ink`       | `#0D0D08` | text, borders, black icon discs                |
| `--ink-muted` | `#6b6b6b` | helper text                                    |
| `--paper`     | `#ffffff` | /live's background                             |
| `--line`      | `#cccccc` | hairlines                                      |
| `--accent`    | `#FFD100` | radio stripe, play disc (yellow for now)       |
| `--signal`    | `#DA291C` | liked, visited, the actual line, post dots     |
| `--plan`      | `#999999` | the planned line                               |

### Controls

- Tabs and buttons: 44 px tall (Apple's minimum touch size).
- Radio stripe: 32 px visible, 44 px tap area.
- Icons: 20 px in the stripe and the like row; 32 px for map zoom.

## Icons

IBM's Carbon icons (`@carbon/icons`, Apache-2.0; checked at 11.92.0).
Copy only the SVGs used into the repo, with the license beside them.
Filled versions with a meaningful color are preferred over outlines.

| Use                  | Icon                              | Color                                  |
|----------------------|-----------------------------------|----------------------------------------|
| Radio play           | `play--filled`                    | yellow disc, black ▶ (its inner path)  |
| Radio stop           | `stop--filled`                    | black disc, yellow ■ (inner square added by us) |
| Like, off / on       | `favorite` / `favorite--filled`   | black outline → red (`--signal`)       |
| Map zoom             | `add--filled` / `subtract--filled`| black disc, white + / −                |
| Close a box          | `close--filled`                   | black disc, white ×                    |
| Radio links          | `link`                            | black outline                          |
| Tile maximize/restore| `maximize` / `minimize`           | black outline                          |

Color meaning: yellow is play or go, red is something that happened
(liked, visited), black is a plain control.

## Later

- Desktop layouts for every view.
- Color, as a whole: the palette here is deliberately plain so it can be
  looked at all together later. Yellow (`--accent`, the stripe) is a
  placeholder.
- Tuning on a phone, if needed: the pinch threshold (×1.5), the sun-event
  window (15 min), the hourly stop width on the timeline (~⅓ of the
  screen). Start with these.

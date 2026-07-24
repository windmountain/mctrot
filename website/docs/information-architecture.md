# McTrot Website — Information Architecture

Domain: **mctrot.nyc**. Contact: **admin@mctrot.nyc**.

Plain static HTML. No site generator, no build step, no programmatic anything for v1.

## Framework

Modeled loosely on [tourdivide.org](https://tourdivide.org) — a self-supported,
honor-system endurance challenge site. McTrot adapts this despite being, so far,
solo: the site presents the *challenge* as an open, web-administered format ("a
McTrotter must...", already the voice of `about/rules.txt`), not a personal diary.

Zach's own participation is minimized. He's "McTrot admin," and separately,
without narrative emphasis, a four-time entrant and current record holder. No
part of the site's structure should depend on whether other entrants exist.

## Tone

Factual - blunt, focused. Not telling you how to feel.

Legalistic — the same voice that could have written `about/rules.txt.` Avoid
first-person/personal-diary voice.

Serious - not here to indulge in the taste of McDonald's. This is a difficult
challenge. It is cold. There are risks.

## V1 pages

In order of priority:

1. **Home** — leads with the challenge itself (tagline + short description),
   format-first.
2. **Rules** — rendered from the existing `about/rules.txt`.
3. **Route** — brief description of the requirements and challenges of picking
   route. (Heuristics, TSPTW, walking-distance-along-sidewalks, time windows)
   with a link to this repo for tooling/solvers. No cannonical map or solver
   output.
4. **Results** — per-attempt record (date, time, entrant), framed generically,
   not personal narrative.

## Deferred (not v1, but planned IA slots)

- **Route page enhancements** — historical maps
- **History of McDonald's in Manhattan** — the microfiche research in
  `historical-locations/`, a genuinely unique content asset distinct from the
  Results archive.
- **Sponsors** — the Shoe Deal contract (`shoe-deal/`).

## Furniture

- Title/wordmark on every page (visual style/placement not yet decided).
- Nav: Home, Rules, Route, Results. Placement (header vs. elsewhere)
  intentionally tabled.
- Footer links: Instagram, this GitHub repo, contact email.
- Footer boilerplate line (locked):

  > McTrot is self-administered. Honor system only — no verification, no
  > prize, nothing at stake but the eating and the walking. Disputes,
  > questions, and challenges to the record: admin@mctrot.nyc.

- No dedicated Contact page for v1 — the footer email covers it.

## The End

V1 should work end-to-end with room to grow gradually, rather than starting
broad and filling in many sections at once. IA was deliberately settled
before any HTML or aesthetic work began.

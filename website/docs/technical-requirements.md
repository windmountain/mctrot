# McTrot Website — Technical & Accessibility Requirements

Companion to `information-architecture.md`.

## JavaScript

None by default. JS is only acceptable when there's a good reason and no
sensible non-JS alternative — and even then, the site must keep working with
JS disabled. Don't reach for a script to solve something CSS or plain HTML
can do.

## Browsers

Broad, conservative support. Old iPhones stuck on outdated iOS (and therefore
outdated Safari, since the two are tied together) can't update their way out
of that, and this skews toward people who can't or don't replace hardware
often.

## Devices and network

No mobile-first/desktop-first split. The site should be simple enough that
it reads equally well on either, without device-specific tailoring. 

Design for weak/unreliable connections: strict page-weight budget, optimized
and minimal assets, no dependency on a fast or stable connection to render
or navigate.

## Client capabilities

The site should account for:

- **Dark mode** (`prefers-color-scheme`) — adapt to the visitor's OS/browser
  preference.
- **Reduced motion** (`prefers-reduced-motion`) — respected for any
  animation or transition, now or later.
- **Print stylesheet** — Rules (and likely Route) should print cleanly.
- **Forced-colors / high-contrast mode** — the site stays usable under
  Windows High Contrast Mode / the `forced-colors` media query.

## Analytics

Not part of this doc — visitor tracking is a legal/regulatory question
(privacy, cookie/consent implications) to be worked out separately.

## Accessibility

**WCAG 2.1 AA is the sitewide floor.** Every page — semantic HTML, sufficient
color contrast, alt text, keyboard navigation, correct heading structure —
must meet AA, no exceptions.

**AAA almost everywhere.** Home, Route, and Results are short and factual by
design (see IA doc's tone requirements), so they should also clear AAA
criteria without extra effort. Treat AAA as the target on these pages, not
just AA. Colors should have enough contrast.

**Rules gets a plain-language summary, not a rewrite.** The Rules page's
legalistic register (matching `about/rules.txt`) will not satisfy 3.1.5
Reading Level (AAA) as written. Add a short plain-language summary
("in short:") above the full rules text. WCAG 3.1.5 is explicitly satisfied
by providing a supplemental version, so this lets the Rules page also clear
AAA without touching the original register.

Conformance is tracked per page.

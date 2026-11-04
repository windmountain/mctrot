# Collaborative mega search (idea)

> **Idea only. Nothing here is built.** Don't treat this as a description of the
> current site or as a plan in progress unless asked about it. Today the mega search
> (`mega-search.html`) has no server: it runs entirely in one browser and keeps a
> single search in localStorage.

Visitors run the mega search and pool their results into one shared landscape that the
site and other visitors can read. Every cell's result is deterministic: it's fixed by
the data version, the code version (cost function, annealing schedule, chunking, Elm's
random generator), the settings and the seed. So there is one correct answer per cell,
and the shared system's job is to collect those answers and check them, not to rank
"better" routes.

## Where the work comes from

- The server holds the grid: every cell for the current data and code version, made
  from fixed choices of start time, start point, pace, stop length and seed.
- A visitor who opens the page asks for work. The server decides what they get, and
  visitors never choose. A batch mixes fresh cells with cells someone else has already
  computed, and nothing marks which is which.

## Doing the work

- The browser computes each cell and sends back the result: the route, its time and
  its distance.
- The visitor never sees anyone else's answer. Each one just computes and reports.

## How results are checked

- **Fresh cells** are stored as unconfirmed, tagged with the submission and the
  anonymous contributor they came from.
- **Repeated cells** are compared with what's stored:
  - If they match, both submissions gain confidence.
  - If they don't, the cell goes to a few more random visitors. The majority decides,
    with the server rerunning the cell only as a last resort. Whoever was wrong has
    their whole submission redacted.
- Each submission's repeats are spread over many different visitors, so getting a fake
  past the checks means controlling nearly all of them.
- On top of random sampling, any notable result is always checked: anything entering
  the top results, and any cell far better than its neighbors in time or place.
  Random sampling is weak against a few targeted fakes, and those are the cells people
  look at.

## Trust

- Every contributor is an anonymous browser identity that builds a record as its work
  passes checks.
- A new identity's work is accepted, but its checks of other people's work count for
  little until it has a record.
- So building a crowd of fake identities takes as much honest computing as doing the
  work.

## Confidence

- Each submission carries a level: "if more than p of it were wrong, we'd have caught
  it with probability c". It rises as more of its cells are checked, including checks
  made long after it was submitted.
- Each cell inherits its submission's level, or is marked verified once two independent
  sources agree on it.

## Redaction

- It can happen at any time, including long after the fact, if a later check finds a
  mismatch.
- It removes the whole submission and, optionally, everything else from that
  contributor.
- The board is always calculated from submissions still in good standing, so redacted
  results drop out of it, including best-of-seeds figures and top results. Cells only
  they covered go back to the pool. Redacted data is kept for auditing and in case a
  redaction needs undoing.

## What visitors see

- The landscape fills in and sharpens as more people contribute, with unconfirmed cells
  shown differently from verified ones.
- A visitor can see their own contributions, and later checks can raise or lower their
  confidence.

## The server's whole job

Hand out work, compare results, keep trust scores, redact, and serve the board. It
rarely computes a route itself.

## Before any of it is worth building

- **Make `exp` deterministic** (see below), so honest visitors on different browsers
  can't disagree.
- **Fix the grid choices** (start times, start points, paces, stop lengths, seeds) so
  results from different visitors land in the same cells. Free-typed pace and stop
  length would scatter them.
- **Version the data and the code.** A cell's identity includes both, so re-scraped
  hours or a changed search start a new board.

## Appendix: confidence numbers

If a submission has n cells, a fraction p of them are wrong, and k cells are rechecked
at random, the chance of missing every wrong one is about (1 − p)^k. The number of
checks barely depends on n:

| Claim | Checks needed |
|---|---|
| 95% sure that under 5% is wrong | ~59 |
| 99% sure that under 5% is wrong | ~90 |
| 95% sure that under 1% is wrong | ~299 |
| 99% sure that under 1% is wrong | ~459 |

For splitting checks across verifiers: if a cheater controls a fraction q of active
verifiers and a submission's checks go to m different verifiers, all of them being the
cheater's is about q^m. For example, q = 10% and m = 5 gives about 1 in 100,000.

All of this assumes the cells to check are chosen by the server after the submission
arrives, with randomness the submitter can't predict.

## Appendix: deterministic `exp`

**Why it's needed.** The search uses `^` on floats in two places:
`roll < e ^ (-delta / temp)` in `src/SimulatedAnnealing.elm`, for accepting a worse
move, and `initial * alpha ^ iteration` in `src/SimulatedAnnealing/Schedule.elm`, for
the temperature. Both compile to `Math.pow`. JavaScript requires `+ − × ÷` to give
exactly rounded results, but lets each engine approximate `Math.pow` and `Math.exp`
its own way, so Chrome, Firefox and Safari can differ in the last bit. Everything else
is already exact: Elm's random generator, walking times by plain division, and
whole-minute route times.

**How much it matters.** A last-bit difference changes an outcome only when the random
number lands in that gap, at odds of about 1 in 10^16 per comparison. With about
180,000 steps per cell and 4,462 cells in the default grid, that's roughly one expected
disagreement in ten million full grids. That's rare, but a system that redacts on
mismatch shouldn't rest on "rare".

**The approach**, using only `+ − × ÷` and `round`:

- Split x as k·ln2 + r, with k a whole number and |r| ≤ ln2/2, so e^x = 2^k · e^r.
- Compute e^r with a Taylor series of about 13 terms, evaluated by Horner's method and
  written out as one expression so nothing is allocated.
- Get 2^k from a table of 2^0 to 2^−60, built once by halving. Every entry is exact.
- Return 0 below a cutoff around x = −40. The random roll is essentially never below
  e^−40 ≈ 4×10^−18, and the cutoff keeps k small. It's part of the definition, so it's
  just as deterministic.
- For the temperature, use `initial * exp (iteration * lnAlpha)` with ln(alpha) written
  as a constant, or carry the temperature forward by multiplying by alpha each step.

**Cost.** The estimate is 1–3%, against about 7 µs per annealing step. This needs
measuring.

**Effect on existing results.** The new `exp` differs from `Math.pow` by a unit or two
in the last place, so existing routes and simulator links almost certainly won't
change. Confirm by rerunning a sample before and after. It still counts as a new code
version.

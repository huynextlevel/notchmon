# Design notes

Why notchmon is built the way it is. The README says what it does; this says
what had to be true for that to work, and what was measured rather than assumed.

## The one constraint worth knowing

**The notch has no pixels.** It is a hole cut for the camera, not a dark region
of screen — nothing can be drawn inside it, by this app or any other. What makes
an overlay read as *part of* the notch rather than parked underneath it is two
things, and notchmon does both:

1. It owns the two menu-bar strips AppKit calls `auxiliaryTopLeftArea` and
   `auxiliaryTopRightArea`, and leaves a gap the exact width of the notch
   between them. Content that stops at the notch's edge and resumes on the far
   side reads as passing *behind* it.
2. It grows a pure-black shape out of the notch whose top corners flare
   *outward* into the bezel, the way the notch's own moulding does. One shape,
   two sizes — so the hardware notch never stops being part of the silhouette
   and no second object ever appears.

## What the strip shows

Left of the notch: the **two tools used most recently**, each as its brand
mark and how much of its *session* window is left — the one number that
decides whether the next prompt goes through. Right of the notch: today's
tokens. Nothing else, because the menu bar's own items start a hundred points
either side.

"Most recently" comes from `tokscale hourly`, so a quota you hold but have not
touched all week (a Copilot plan that came with a GitHub account, say) still
appears in the expanded panel but never takes one of the two slots.

Colour is identity, not status: every bar and mark is its brand's colour —
Claude terracotta, OpenAI and Cursor white, Copilot violet, Gemini blue — and
only turns red in the last fifteen percent of a window.

## Where a window is heading

tokscale answers "how much is left right now" and nothing else — it keeps no
history, and neither do the other Swift notch apps. So NotchMon records every
quota reading it takes and folds the recent ones into a **pace**: which way the
window is moving, what share of the allowance the current rate will have spent
by reset, and — when that lands past 100 — **how long until it runs out**.

The fold and its three constants come from
[TokenBar](https://github.com/Nanako0129/TokenBar) (MIT), which measured them
against live curves. Two details there are load-bearing and look like bugs:

- **The projection has a floor but no ceiling.** "Runs out early" *is*
  `projected > 100`, so capping at 100 would delete the only signal the fold
  exists to produce.
- **Rate is never expressed per hour.** A 5-hour window must burn ~20%/h to
  spend its allowance; a 7-day window only ~0.6%/h. Any %/h figure names the
  shortest window as the most urgent regardless of behaviour.

Window length is the missing piece — tokscale reports a reset time but never a
window start. It is **measured** by watching a reset move (the gap between two
consecutive resets is the duration) and falls back to reading the window's own
name. A label neither route recognises gets no projection, which is the right
answer: a guessed duration produces a confidently wrong slope.

Samples are admitted **by time, never by value**. Dropping a repeated reading
sounds like noise reduction and is the opposite — burn all morning, stop, and
every afternoon poll repeats the same number and is discarded, leaving the
morning's climb as the newest data and projecting a burn that ended hours ago.

## Where the numbers come from

[`tokscale`](https://www.npmjs.com/package/tokscale), the same Rust CLI
[token-monitor](https://github.com/Javis603/token-monitor) uses, spawned as a
subprocess:

| what | command | drives |
| --- | --- | --- |
| subscription quotas | `tokscale usage --json` | the rings, the reset countdowns |
| today's tokens and cost | `tokscale --json --client <all> --group-by client,model --today` | the spend figures |
| when each tool was last used | `tokscale hourly --json --week` | the order of the strip |
| supported tools | `tokscale --help` | the `--client` filter, so a tokscale upgrade picks up new tools with no code change here |

It reads credentials already on disk (`~/.claude`, `~/.codex`, the keychain);
notchmon itself stores nothing and sends nothing anywhere.

## Layout

```
Sources/NotchMon/
  App/     entry point, delegate, status item, preferences, settings window
  Notch/   geometry, the shape, the panel, the hover state machine
  UI/      design constants, rings, idle strip, expanded panel
  Usage/   tokscale subprocess, decoding, polling store
```

## Things to know

- **It pins itself to the display with a real notch**, not to `NSScreen.main`.
  Main follows the key window, so on a desk with an external monitor it flips
  every time focus moves — and the app would draw an invented notch on a screen
  that has none.
- **Why Copilot shows up when token-monitor never listed it.** token-monitor
  only reports a Copilot quota after you log in through its own device-flow;
  tokscale reads the GitHub token already on the machine. Same account, one
  extra step skipped.
- **Space switches.** The panel is `.stationary` and `.canJoinAllSpaces`, and
  re-asserts its frame and ordering on `activeSpaceDidChange`, so it holds
  still with the hardware while the desktop slides underneath it.
- **It leaves when an app goes full screen, and only on that display.** The
  first version stayed, on the argument that the notch is physically there in
  full screen too. That argument loses to the one already governing Mission
  Control: the strip is welded to the menu bar and goes where the menu bar goes.
  Mission Control leaves the bar up, so the strip stays; full screen takes the
  bar away, so the strip leaves with it.

  There is no public API for it. The window list is not one — a full-screen
  app's window appeared in one sample out of eighteen while the app sat in full
  screen throughout. Nor is the menu bar hiding: `frame.maxY - visibleFrame.maxY`
  measured 39 points in every sample, full screen or not.
  `CGSCopyManagedDisplaySpaces` answers it per display, which is the part that
  matters — a browser taken full screen on an external monitor must not blank
  the strip on the built-in one. Two signals off that record are accepted, the
  space's `type` of 4 and the `TileLayoutManager` boring.notch reads; both were
  measured to agree on every sample of an enter/exit cycle.
- **It never eats a menu-bar click.** The panel is 680 points of window laid
  across the menu bar, so it is made transparent to the mouse whenever the
  pointer is not literally on the drawn shape, and its hosting view hit-tests
  only the shape's own rect.
- **Which window the ring shows is chosen by time, not by level.** It used to
  be the fullest window across all of them, which compared quantities that share
  no scale: a 7-day at 84% left and a 5-hour at 89% left say nothing about which
  you hit first. Now the ring takes whichever window runs out soonest in
  wall-clock seconds, and falls back to the fullest only when none is at risk.
- **Refreshes are rate-limited.** Opening the notch asks for fresh numbers but
  will not refetch within 45 seconds; the menu's "Refresh now" always does.

## When a break reminder fires

Not chosen by feel. The interval comes from the literature; the *cost* of the
interruption is what scales, because thirty minutes is the number the evidence
keeps returning and an app that opens the notch every half hour gets switched
off in a week.

| Sitting | What happens | Why that number |
| --- | --- | --- |
| 30m | the mark changes, nothing opens | Five minutes of walking every 30 was the only pattern that moved both blood pressure and post-meal glucose ([Diaz 2023](https://www.cuimc.columbia.edu/news/rx-prolonged-sitting-five-minute-stroll-every-half-hour)); the [2015 sedentary office statement](https://pubmed.ncbi.nlm.nih.gov/26034192/) asks for a posture change every 30 |
| 60m | the notch opens for four seconds | [Directive 90/270](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A31990L0270) requires screen work to be broken up but names no number; the working benchmark is 5–10 minutes away every 50–60, and no continuous screen hour |
| 90m | same size, critical colour | Where `Presence.restAfter` already sits. Breaks of ≤10 minutes cut fatigue and raise vigour across 22 studies ([Albulescu 2022](https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0272460)) |
| 2h+ | the panel drops down, once per stretch | Nothing in the literature says two hours. It is the point at which the quieter sizes have been ignored twice |
| 5m away | the stretch resets | Already `Presence.restTolerance`, and five minutes is the dose that carried the physiological effect |

- **Read and deliberately not used.** Pomodoro (25/5) is a focus technique with
  no ergonomic evidence behind its numbers, and 52/17 is one company's product
  telemetry rather than a study. 20-20-20 is recommended everywhere and
  [has not tested well](https://www.aaojournal.org/article/S0161-6420(22)00361-X/fulltext),
  which is why the EYES sprite ships tied to twenty minutes and **off** by
  default. Cornell is the strictest source found, at
  [1–2 minutes of movement every 20–30](https://ergo.human.cornell.edu/CUESitStand.html).
- **Settings carries one switch: Break reminders, on by default.** It stops
  every size above — the mark stops changing, the notch stops opening, the panel
  stops dropping — and changes nothing else. The Time tab still counts and the
  strip still says how long you have been sitting, because measuring and
  interrupting are two different consents and only the second one is annoying.
  Under it, the loudest size allowed is itself a choice, so someone who never
  wants the panel can cap it at the pill.

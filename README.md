# notchmon

**Quota, spend and session usage for every AI coding agent on your Mac — Claude
Code, Codex, Gemini CLI, Cursor, Copilot and 48 more — in the menu bar and the
MacBook notch.**

Idle, it sits in the two menu-bar strips either side of the camera housing.
Hover it and the notch grows downward into a panel with every provider's quota
windows, today's spend, and when each limit resets.

## Supported agents

Most Mac usage trackers read one tool. notchmon has **no built-in list of
agents at all** — it shows whatever `tokscale` can read on the machine, which
today is 53 clients:

`amp`, `antigravity`, `antigravity-cli`, `augment`, `cherrystudio`,
`claude`, `cline`, `codebuddy`, `codebuff`, `codex`, `commandcode`,
`copilot`, `crush`, `cursor`, `devin-cli`, `devin-desktop`, `droid`, `dsh`,
`freebuff`, `fx`, `gemini`, `gjc`, `goose`, `grok`, `hermes`, `hindsight`,
`jcode`, `junie`, `kilo`, `kilocode`, `kimchi`, `kimi`, `kiro`, `lmstudio`,
`mcode`, `micode`, `mux`, `omp`, `openclaw`, `opencode`, `opencodereview`,
`pi`, `prime-agent`, `qwen`, `reasonix`, `roocode`, `senpi`, `trae`,
`unsloth`, `warp`, `workbuddy`, `zcode`, `zed`

You only ever see the ones you actually use; the rest never appear. When
tokscale learns a 54th, it shows up here with no change to notchmon and no
update to install. A test pins that behaviour
(`ProjectFoldTests.testAnUnknownAgentStillAppears`), because it is the one
property that would be easy to break and hard to notice.

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

## Build

```sh
make vendor          # fetch the tokscale binary into vendor/
make app             # assemble dist/NotchMon.app
make run             # build and launch
make dmg BUILD=2     # the drag-to-Applications installer
```

`make dmg` lays the installer window out by asking Finder to do it, which macOS
gates behind Automation — the first run raises a prompt that has to be allowed.
Refuse it and you still get a working disk image, with Finder's default view and
no background.

Requires Swift 6 and Node (only to fetch the tokscale binary — nothing Node
ships is loaded at runtime).

## Updates

Sparkle, the one dependency in the app. Two switches in Settings, because they
are two different permissions: knowing a version exists, and letting the app
replace itself without being asked.

Updates are verified twice over — an EdDSA signature whose public half is baked
into every copy already installed, and Apple code signing. The feed can be
served from anywhere without that being a way in.

`Scripts/release.sh` regenerates `appcast.xml` on every release. The DMG then
has to be attached to the matching GitHub release, because the enclosure URL in
the feed points there.

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
- **It stays visible over full-screen apps.** The notch is physically there in
  full screen too, so the strip is as well. If an app draws content up under the
  notch, the strip covers that band.
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

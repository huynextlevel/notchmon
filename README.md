<div align="center">

<img src="docs/images/icon.png" width="88" alt="notchmon">

# notchmon

**Quota, spend and session usage for every AI coding agent on your Mac — drawn into the MacBook's own notch.**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-1c1c1e?logo=apple&logoColor=white)
![universal](https://img.shields.io/badge/universal-arm64%20%2B%20x86__64-1c1c1e)
![53 agents](https://img.shields.io/badge/agents-53-d0663f)
![notarized](https://img.shields.io/badge/notarized-Developer%20ID-1c1c1e)

<img src="docs/images/strip.png" width="640" alt="The idle strip: Claude at 98% of its session window, Codex at 100%, 20.0M tokens today.">

</div>

## What is notchmon?

One glance, no window: how much of each agent's quota is left, and what today has
cost. It lives in the two menu-bar strips either side of the camera housing.
Hover it and the notch grows downward into a panel.

Most Mac usage trackers read one tool. notchmon has **no built-in list of agents
at all** — it reads whatever [`tokscale`](https://github.com/junhoyeo/tokscale)
can find on the machine, which today is 53 clients. You only ever see the ones
you actually use.

> The screenshot above cannot show the notch, because the notch is not pixels —
> it is a hole cut for the camera. On the machine, the gap in the middle of that
> strip is the camera housing, and the strip reads as passing behind it. See
> [design notes](docs/notes.md) for how that illusion is held together.

## Supported agents

`claude` · `codex` · `cursor` · `gemini` · `copilot` · `opencode` · `amp` ·
`droid` · `kimi` · `qwen` · `crush` · `goose` · `zed` · `warp` · `cline` ·
`grok` · `augment` · `devin-cli` · `junie` · `trae` · `kiro` — and 32 more.

<details>
<summary>All 53</summary>

`amp`, `antigravity`, `antigravity-cli`, `augment`, `cherrystudio`, `claude`,
`cline`, `codebuddy`, `codebuff`, `codex`, `commandcode`, `copilot`, `crush`,
`cursor`, `devin-cli`, `devin-desktop`, `droid`, `dsh`, `freebuff`, `fx`,
`gemini`, `gjc`, `goose`, `grok`, `hermes`, `hindsight`, `jcode`, `junie`,
`kilo`, `kilocode`, `kimchi`, `kimi`, `kiro`, `lmstudio`, `mcode`, `micode`,
`mux`, `omp`, `openclaw`, `opencode`, `opencodereview`, `pi`, `prime-agent`,
`qwen`, `reasonix`, `roocode`, `senpi`, `trae`, `unsloth`, `warp`, `workbuddy`,
`zcode`, `zed`

</details>

When tokscale learns a 54th, it appears with no update to notchmon and no code
change here. A test pins that behaviour
(`ProjectFoldTests.testAnUnknownAgentStillAppears`), because it is the one
property that would be easy to break and hard to notice.

## Showcase

**Overview** — today's tokens and cost, a dial per agent showing what is left of
the window that runs out soonest, and a year of activity.

<img src="docs/images/overview.png" width="700" alt="Overview: 19.3M tokens today, $15.02. Claude 98% left with 2h 35m to reset; Codex 100% left. A year-long activity grid with 60 active days.">

**Projects** — today's spend split by repository, then by agent, then by model,
with the token mix underneath. Cache reads are usually most of the volume, and a
bare token count hides that.

<img src="docs/images/projects.png" width="700" alt="Projects: huypham at $15.46, 20.0M tokens, claude on opus-5, token mix showing 19.3M cache read against 124 input.">

**Settings** — in the notch, not a window. Pin agents to the strip, choose one of
five themes, set the refresh clocks, pick the alert threshold.

<img src="docs/images/settings.png" width="700" alt="Settings: agents with pins and switches, five theme swatches, general toggles including update switches, strip and refresh and alert options.">

## Features

**Quota**
- Every provider's session and weekly windows, with the time until each resets.
- The ring shows whichever window **runs out soonest in wall-clock time**, not
  the fullest one — a 7-day at 84% and a 5-hour at 89% say nothing about which
  you hit first.
- A **pace** projection: which way the window is moving, what share the current
  rate will have spent by reset, and when it runs out if that lands past 100%.
- One alert per window at 50 / 75 / 90%. The notch flashes; nothing is sent to
  Notification Centre.

**Today**
- Tokens and cost, per agent and per model.
- Per project, with input / output / cache-write / cache-read split out.
- A year of daily activity, in the theme's own colour.

**In the notch**
- A pixel sprite runs in an agent's mark while that agent is working — detected
  from session files on disk, not from a hardcoded list of processes. Two styles,
  adjustable beat, or off.
- Five themes: Ink, Obsidian, Anodized, Sable, Vapor.
- Stands down while Mission Control is up.
- Follows the display you are working on, or shows one strip per display.

## Install

Download the latest **`.dmg`** from
[Releases](https://github.com/huynextlevel/notchmon/releases), open it, and drag
notchmon to Applications.

The app is signed with a Developer ID certificate and notarized by Apple, so it
opens with a double-click — no right-click-Open, no Gatekeeper warning.

## Requirements

- macOS 14 or later
- A MacBook with a notch. notchmon pins itself to the display that has one
  rather than to whichever screen has focus, and will not draw an invented notch
  on a screen without one.
- Apple silicon or Intel — the build is universal, and so is the tokscale binary
  inside it.

## Updates

Two switches in Settings, because they grant two different things: knowing a
version exists, and letting the app replace itself without being asked.

Updates go through [Sparkle](https://sparkle-project.org) and are verified twice
over — an EdDSA signature whose public half is baked into every copy already
installed, plus Apple code signing.

## Privacy

Everything stays on the machine. notchmon spawns `tokscale` as a subprocess,
which reads credentials and session files already on disk (`~/.claude`,
`~/.codex`, the keychain). The app itself stores nothing beyond its own settings
and a local history of quota readings, and sends nothing anywhere.

The only network traffic it makes on its own is the update check, and only while
that switch is on.

## Build from source

```sh
make vendor          # fetch the tokscale binary into vendor/
make app             # assemble dist/NotchMon.app
make run             # build and launch
make dmg BUILD=n     # the drag-to-Applications installer
```

Needs Swift 6, and Node only to fetch the tokscale binary — nothing Node ships
is loaded at runtime.

`make dmg` lays the installer window out by asking Finder to do it, which macOS
gates behind Automation: the first run raises a prompt that has to be allowed.
Refuse it and you still get a working disk image, with Finder's default view and
no background.

## Design notes

[docs/notes.md](docs/notes.md) — why the notch illusion needs two things rather
than one, how a window's length is *measured* rather than guessed, why samples
are admitted by time and never by value, and the rest of what was learned the
hard way.

## Credits

- [tokscale](https://github.com/junhoyeo/tokscale) — the CLI every figure here
  comes from.
- [TokenBar](https://github.com/Nanako0129/TokenBar) — the pace fold and its
  three empirical constants.
- [codenotch](https://github.com/vinzdg/codenotch) — brand-mark outlines.
- [Sparkle](https://sparkle-project.org) — updates.

Full notices in [THIRD_PARTY.md](THIRD_PARTY.md).

# Absolute Virtue Helper (avhelper)

Ashita v4 addon for the Absolute Virtue fight on Catseye XI. Watches for AV's
special-ability reactions, alerts you with a countdown to counter them, and
shows which are still live vs. locked for the rest of the pull.

## Installation

1. Copy the `avhelper` folder into your Ashita `addons` directory, so you
   have `Ashita\addons\avhelper\avhelper.lua`.
2. In-game, run `/addon load avhelper` (or add `avhelper` to your character's
   Ashita profile to load it automatically).

## How it works

- When AV uses one of the tracked abilities, the window shows an alert and a
  10-second countdown.
- If anyone in the alliance uses the matching real ability within that
  window, it locks for the rest of the pull.
- A fresh pull is detected automatically from AV's engage speech in chat.
  `/avh reset` also works manually at any time.
- Your current job is auto-detected. If it's one of the tracked 2-hour jobs,
  that ability's name is highlighted in a colorblind-friendly blue, and AV
  using that specific reaction plays a different notification sound than the
  normal alert.

Tracked abilities: Mighty Strikes, Benediction, Hundred Fists, Manafont,
Chainspell, Perfect Dodge, Invincible, Blood Weapon, Soul Voice, Meikyo
Shisui, Eagle Eye Shot, Call Wyvern.

## Commands

| Command | Effect |
|---|---|
| `/avh` | Toggle the window |
| `/avh show` / `/avh hide` | Show/hide the window |
| `/avh reset` | Clear all lock/unlock state |
| `/avh mute` / `/avh unmute` | Toggle sound alerts |
| `/avh speechreset on` / `off` | Toggle auto-reset on AV's engage speech |
| `/avh abilities` | List tracked abilities and resolved ids |
| `/avh lock <job>` | Manually mark that job's 2hr LOCKED (e.g. `/avh lock drg`, `/avh lock sam`) - a fallback for when auto-detection misses a real lock |
| `/avh unlock <job>` | Manually mark that job's 2hr UNLOCKED again (e.g. `/avh unlock sam`) - for undoing a mistaken lock |
| `/avh help` | Show the command list |

Job codes for `/avh lock` / `/avh unlock`: `war whm mnk blm rdm thf pld drk
brd sam rng drg` (one per tracked 2-hour ability, in that order: Mighty
Strikes, Benediction, Hundred Fists, Manafont, Chainspell, Perfect Dodge,
Invincible, Blood Weapon, Soul Voice, Meikyo Shisui, Eagle Eye Shot, Call
Wyvern).

## Configuration

Settings are saved per-character under:
```
Ashita\config\addons\avhelper\<CharName>_<ServerId>\settings.lua
```
Day-to-day changes are easier via the `/avh` commands above than editing
this file directly.

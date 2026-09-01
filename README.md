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
- A fresh pull is detected automatically from AV's engage speech in chat, or
  on zoning. `/avh reset` also works manually at any time.

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
| `/avh mobname <name>` | Change the mob name being watched for |
| `/avh speechreset on` / `off` | Toggle auto-reset on AV's engage speech |
| `/avh phrases` | List the speech phrases that trigger an auto-reset |
| `/avh addphrase <text>` | Add a speech phrase, pasted straight from chat |
| `/avh delphrase <number>` | Remove a speech phrase by its number |
| `/avh abilities` | List tracked/disabled abilities and resolved ids |
| `/avh enable <name>` / `/avh disable <name>` | Add or remove an ability from tracking |
| `/avh help` | Show the command list |

## Configuration

Settings are saved per-character under:
```
Ashita\config\addons\avhelper\<CharName>_<ServerId>\settings.lua
```
Day-to-day changes are easier via the `/avh` commands above than editing
this file directly.

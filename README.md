# Solaryn's Expedition

**Quest routing and zone exploration for WoW: Forever.**

Solaryn's Expedition helps you quest an area well without turning the game into "follow the arrow". It works out a sensible order for the quests in your log and shows you where the next one is, then gets out of the way. You stay focused on questing and on exploring Azeroth. Less time lost, more time playing.

- **Plan the area, not just the next step.** Your quest log becomes a walking route that finishes the objectives around you before sending you back to town to hand everything in.
- **Guidance when you want it.** Start the guide and the waypoint moves on by itself as you finish each quest. Or ignore it and just use the panel to see what's nearby.
- **Exploration is part of the game.** See how much of each zone you've discovered, which areas are left, and where to level next.

> **Status:** beta, built for the WoW: Forever beta client (interface 16001). Feedback and bug reports are very welcome. See [Reporting problems](#reporting-problems).

---

## About

**Solaryn** is my main, an Alliance Druid on the Gurubashi realm in retail, and the character I always come back to. The add-on carries his name because it's built the way he plays: wandering, questing, and seeing every corner of the map.

I've played World of Warcraft since 2005 and have never stopped loving it. Druid is my home, but I'm a proud altoholic with more characters than I'd like to admit, which means a *lot* of time spent asking the same two questions:

- *"Where do I turn this quest in?"*
- *"What zone should I be in right now?"*

Solaryn's Expedition is my answer, and it sits between the tools that are already out there. Questie shows you everything on the map; RestedXP hands you a step-by-step script. This add-on aims for the middle ground, and you choose how much of it to use:

- **As a route guide:** the on-screen tracker walks you through your quests in a sensible order, area by area, and keeps the route up to date as you pick quests up and finish them.
- **As a companion for exploring:** leave the guide off and use it to see where your quests and their hand-ins are, which zone suits your level, what an NPC has to offer, and how much of each zone you've discovered.

Either way, the aim is the same: less time lost, more time enjoying Azeroth.

---

## Features

### The panel (`/sol` or the minimap button)
Three tabs:
- **Next:** what to do now, nearest first. Ready hand-ins, quest objectives with their distance and level (coloured like the quest log), and a suggested new zone once you've outgrown yours.
- **Route:** your quests in walking order. Click any stop to be guided from there.
- **Zones:** where to level (your zone's level range and the nearest zones that fit you) and how much of each zone you've explored.

The top of the panel always shows your current zone, its level range and how much of it you've explored.

### Route guide
- **Always up to date:** the route rebuilds itself whenever you accept, finish, hand in or drop a quest. While you're being guided, finished stops stay done and new quests slot in where they fit best.
- **Areas first:** objectives near you come before walking back to hand in. A hand-in right on your way is picked up immediately.
- **Moves on when the work is done:** a stop counts as done when the quest's objectives are complete, not just because you arrived. When you finish a quest, its hand-in is added to the route and the rest is re-planned from where you stand.
- **Numbered map pins:** route stops show on the world map. Hover a pin for details or click it to set a waypoint.

### On-screen route tracker
A compact tracker, in the style of the built-in quest tracker, appears while you're being guided:
- The current stop, its remaining objectives and a live distance.
- A **direction arrow** relative to the way you're facing.
- The next few stops; click one to jump ahead.
- Header buttons: **rebuild** the route now, **skip** a stop, **stop** guiding, and collapse.
- **Quest item buttons** for usable quest items in your bags. Bind **"Use quest item (guided quest)"** under *Key Bindings → AddOns*.

### Quest info in tooltips
- **Mobs, NPCs and objects your quests need** show the quest and your progress (`Kobold Camp Cleanup — Kobold Vermin: 4/8`).
- **NPCs you've talked to** show the quests they still offer, with their levels (`Available: [7] The Fargodeep Mine`), and which of your quests they take back. This is learned as you play and shared across your characters.

### Zones and exploration
- **Level ranges:** each zone's level range, coloured by how it suits you, plus advice on the nearest next zone on your continent.
- **Exploration coverage:** taken from your *Explore \<Zone\>* achievement when there is one, so a fully explored zone reads 100%. Hover a zone to see which areas you haven't found yet. Otherwise coverage comes from your world map's revealed areas and where you've walked.

---

## Installation

1. Download the latest code (**Code → Download ZIP**) or clone the repository.
2. Copy the folder into your Forever client's add-on folder and make sure it's named **`SolarynExpedition`**:
   ```
   World of Warcraft/_classic_beta_/Interface/AddOns/SolarynExpedition/
   ```
   The `.toc` file must be directly inside that folder (`.../SolarynExpedition/SolarynExpedition.toc`), not in a nested `SolarynExpedition-main/` folder.
3. Restart the game, or `/reload` if you're updating an existing install.

## Getting started

1. Accept a few quests in the same area.
2. Type **`/sol`**. The **Next** tab shows what's closest.
3. Open the **Route** tab and press **Start guide** (or type **`/sol next`**). The tracker appears and the waypoint follows your progress.

---

## Slash commands

`/sol` and `/expedition` both work. In game, **`/sol help`** lists everything and **`/sol help <command>`** explains one command with an example.

### Panel & guide
| Command | What it does |
|---|---|
| `/sol` | Open or close the panel |
| `/sol next` | Start the guide at the next stop. The waypoint moves on as you finish quests |
| `/sol skip` | Skip the current stop |
| `/sol stop` | Stop the guide (the route is kept) |
| `/sol route` | Rebuild the route from where you stand and print it |
| `/sol map` | Open the world map at the current stop |
| `/sol hud` | Show or hide the on-screen route tracker |
| `/sol options` | Open the options window |

### Quests
| Command | What it does |
|---|---|
| `/sol suggestions` | Print the Next list to chat |
| `/sol where` | Show where each quest's location comes from (or that it has none) |
| `/sol pin <questID>` | Stand where an objective really is and save that spot for the quest. With no ID it lists your quests and their IDs |
| `/sol chain <from> <to>` | Record that one quest leads to another (chains are also learned automatically) |

### Zones & exploration
| Command | What it does |
|---|---|
| `/sol zones` | Print exploration coverage for each zone |
| `/sol zone reset [all]` | Clear the add-on's exploration data for this zone (or all zones). Your map and achievements are read back in |

### Help & troubleshooting
| Command | What it does |
|---|---|
| `/sol help [command]` | The command list, or details and an example for one command |
| `/sol report` | Collect diagnostics (`/sol api` + `/sol where`) in a window ready to copy into a bug report |
| `/sol api` | Report which game features this client supports. Include it with bug reports |
| `/sol debug` | Toggle debug messages |

---

## Options

Open with `/sol options`, the cog on the panel, or right-click the minimap button.
- **Display:** minimap button, panel lock, route pins on the map.
- **Route:** keep the route up to date automatically, auto-build on open, finish nearby objectives before handing in, wait until the quest work is done (or move on when you arrive), arrival distance, quests per route.
- **Route tracker:** show while guiding (or always), lock, size, number of upcoming stops, quest item buttons, tooltip quest info.
- **Exploration tracking:** sampling interval and grid detail.
- **Suggestions:** rank by distance, or by your own weights (distance, level, same zone, hand-ins, story and task quests).

---

## How it works (and its limits)

Solaryn's Expedition **does not ship a quest database**. It uses what the game client tells it and learns the rest as you play:

- **Quest locations** come from the world map's own quest markers. If Forever's client doesn't give a quest a marker, that quest is listed as having no location. `/sol where` shows exactly what the client returns.
- **What NPCs offer** is learned the first time anyone on your account talks to them. NPCs you've never spoken to show nothing yet.
- **Mob tooltips** match a mob's name against your objectives ("kill X", "talk to X"). Mobs that only drop a quest item aren't named in the objective, so they may not be flagged.
- **In combat, especially in groups,** the client hides some unit details from add-ons. Tooltip extras pause in those moments rather than erroring.
- **Zone level ranges and exploration achievements** are matched by English zone name, so other client languages may show fewer of them.
- **Quest item buttons** can't change during combat (a game rule for all add-ons). They update the moment combat ends.

## Reporting problems

Please open an issue with:
1. What you were doing and what you expected.
2. The full error text, if there was one.
3. Your diagnostics: type **`/sol report`**, press **Ctrl+C** in the window that opens (the text is already selected) and paste it into the issue.

The diagnostics are also saved to your SavedVariables (`WTF/Account/<account>/SavedVariables/SolarynExpedition.lua`, under `diagnostics`) when you `/reload` or log out.

---

## Development

The add-on is plain Lua 5.1 with no build step. An offline test suite runs it against a mock of the WoW API, so changes can be checked without the game:

```bash
lua5.1 test/harness.lua            # full test suite
lua5.1 test/check_load_order.lua   # TOC load order check
lua5.1 test/load_addon.lua         # load the add-on and show what got built
```

Run them from the repository root, then copy the add-on files (`*.lua`, `*.xml`, `SolarynExpedition.toc`) into your client's `Interface/AddOns/SolarynExpedition/` folder and `/reload`.

## License

[MIT](LICENSE) © 2026 kwalker430

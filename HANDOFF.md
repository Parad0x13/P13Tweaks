# P13Tweaks – Handoff (2026-11-16)

## What this is
Personal quality-of-life addon for **WoW Forever** (`P13Tweaks.toc`, interface 16001) and
**MoP Classic** (`P13Tweaks_Mists.toc`). Type `/p13` for the options window.

- Project folder: `C:\Users\bryan\Desktop\P13Tweaks` (git, pushed to GitHub `Parad0x13/P13Tweaks`
  `main`; everything below is committed)
- Junctioned into `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\P13Tweaks`
  (`link.ps1` makes the junctions for `_forever_` and `_classic_`)
- SavedVariables: `P13TweaksDB`. Optional dependency: **QuestieDB** (trainer locations).
- Lua errors are hidden in Forever (`scriptErrors` off in `_forever_\WTF\Config.wtf`) – use
  `/console scriptErrors 1` when testing.
- No Lua interpreter on this PC: code is only checked by reading. **Nothing from this session has been
  tested in game** except where the user reported results.
- Adding/removing a file in a `.toc` needs a **full game restart**; other changes need only `/reload`.

## 2026-11-16 (from a Trad0x session) – code committed in 885c94e
- `Features/FishKey.lua`: "Louder splash while fishing" now also sets `Sound_DialogVolume` 0 and
  turns off `Sound_EnableEmoteSounds`, `Sound_EnablePetSounds` and `Sound_EnableErrorSpeech` while
  the line is out. They're restored the same way as the others; a CVar the client lacks is skipped.
  The tooltip is updated. It passed a syntax check but hasn't been tested in game.
- Spells, footsteps and combat noise share the SFX channel with the splash, so they can't be muted
  by CVar. Offered: `MuteSoundFile` for specific sounds the user names.

## How it's built
- `Core.lua`: `ns:RegisterOption(def)`, `ns:Get/Set` (Set calls `onChange` for `key`, `numberKey` or
  `inputKey`), defaults filled on `ADDON_LOADED`, removed-option cleanup, `ns:RegisterCommand(word, help, fn)`.
- `Options.lua`: option types `toggle`, `toggleNumber`, `toggleText`, `toggleSlider`, `toggleButton`,
  `text`, `info`. Inline extras: `before`, `after`, `boxWidth`, `upper`, `maxLetters`, `snap`,
  `min/max/step/format/sliderWidth`, `buttonText/buttonWidth/onClick`.
- `Features/*.lua`: one feature per file, each registers its own options and commands.

## Features (load order in the .toc)
| File | What it does | Commands |
|---|---|---|
| MapCircle | ring shrinks onto you when the map opens | |
| MapSeamless | one seamless zoomable world map (continent ↔ zone handover) | |
| MapMemory | map reopens where you left it | |
| MapMiddleClick + MapCenterKey | middle-click the map to centre on yourself | |
| InteractIcons | floating interact icons on nearby objects (soft-target CVars) | |
| RangeBeep | beep when target is **X yards** (typed; snapped to the nearest checkable range) | `range`, `dot` |
| ProfCap | notice when a profession is at/near its cap; click a row = waypoint to nearest trainer; **right-click your own portrait → "Mark closest Class Trainer" / "General Goods" / "Auction House" (nearest auctioneer, key `AUCTION`) / "Weapon Master" (submenu per weapon; hardcoded `WEAPON_TEACHERS` by NPC name; pre-Cata clients only) / one "Mark closest <Profession> Trainer" per profession (icon, rank-aware via `GuideTo(p)`, list rebuilt each time the menu opens; only professions in `PROF_WORDS`)** | `prof [name\|reset]`, `trainer`, `goods`, `ah`, `weapon [weapon]` |
| MinimapTownsfolk | bank / auction house / anvil (repair) icons on the minimap. Uses the game's own tracking (`MINIMAP_TRACKING_BANKER/AUCTIONEER/REPAIR`) when it exists (MoP); otherwise own pins via Questie's HereBeDragons-Pins, NPCs from ProfCap's QuestieDB scan (`ns.GetTownNpcs("BANK"/"AUCTION"/"REPAIR")`, matched on `LibQuestieDB.Enum.npcFlags` or title). Option `minimapTownsfolk`; `worldmapTownsfolk` = same icons on the world map (own pins on every client, zone/city map only via `HBD_PINS_WORLDMAP_SHOW_CURRENT`). Pin frames pooled. Questie's HBD only redraws world pins on map change/removal, so we set `worldmapProvider.forceUpdate` + `RefreshAllData()` on next map show. Errors reported in chat (pcall) | `townsfolk` (rebuild + counts) |
| FlightPoints | every flight point (own faction + neutral) on the world map via HBD pins, `SHOW_CONTINENT`: white = unlocked, red = not unlocked, grey = unknown. Positions from `C_TaxiMap.GetTaxiNodesForMap(continent)` (fallback: QuestieDB `FLIGHT` flight masters, no status). Known state learned on `TAXIMAP_OPENED` (`TaxiNodeGetType` CURRENT/REACHABLE) into `P13TweaksDB.knownFlights[char] = {names, continents}`; a continent counts as checked once its taxi map was seen. Option `flightPoints` | `flights` |
| FishKey | one key (default `` ` ``) casts Fishing, then becomes Interact to reel in; optional louder splash with SFX % slider | `fish` |
| KillsToLevel | "N more" popup under the character after an XP kill + per-mob kill tally line; kill counts window with per-mob / all clear | `kills`, `killtest`, `killmove` |
| ChatFade | chat hidden until hovered; optional: show for N seconds when a message arrives | `chat` |
| ChatScroll | one wheel notch = one line; Shift = top/bottom, Ctrl = page | |
| SpellReady | chime when a typed spell (default "Skysight", comma list, item names too) comes off cooldown. On cooldown events it sets a `C_Timer` for the ready moment; GCD (≤1.5 s) ignored; only chimes after it has seen the spell cooling. Sound: auction house bell ding (`SOUNDKIT.AUCTION_WINDOW_OPEN`). Option `spellReady` + `spellReadyNames` | `ready` |
| QuestShare | teammates' quests + objective progress, only for group members who also run P13Tweaks (the game exposes no one else's quest log). Addon messages, prefix `P13Q`, on PARTY/RAID/INSTANCE_CHAT: `H^proto` hello (answered with a full list), `C` clear, `Q^id^state^title^+obj~-obj`, `R^id`, `X` sharing off. Own token-bucket send queue (8 burst, 1/1.1 s). Deltas from `QUEST_LOG_UPDATE` (1 s debounce); quests hidden under collapsed headers are kept, not removed. Window ("Ask again" re-sends hello) + tooltip line "Name: 3/10" when an objective text contains the hovered mob/item name. Options `questShare` (+ View), `questShareTooltips` | `quests`, `questsdemo` (pretend teammate = your own log, for testing solo) |

## Sharing with another PC
`installer/Install P13Tweaks.bat` → `installer/Update-P13Tweaks.ps1 -Install`: downloads `main` from GitHub
(API zipball; `$Token` needed while the repo is private), copies into every `_forever_`/`_classic_`
`Interface\AddOns\P13Tweaks` it finds (skips `installer`, `tools`, `link.ps1`, `HANDOFF.md`; never touches a
junction), stores the commit sha in `%LOCALAPPDATA%\P13Tweaks\installed.txt`, adds a hidden Startup-folder
shortcut (`-Quiet`, runs at every Windows start) and a desktop "Update P13Tweaks" shortcut. Log:
`%LOCALAPPDATA%\P13Tweaks\update.log`. Not run yet (repo private, no token).

## Latest session (2026-11-16)
- **QuestShare** (new, multiplayer): see the table row above. Untested in game; `/p13 questsdemo` tests it solo.
- **SpellReady** (new): spell-ready chime (was uncommitted from the previous session).
- **ProfCap trainer titles**: Forever's Zephras Isle Fishing trainer Baelann Swiftcurrent is titled `<Fisher>`
  (Valanaar, 63.3 75.7) and was missed; fishing words are now `fishing`/`fisher`. Also First Aid
  `medic`/`physician`/`surgeon` and Leatherworking `leathercraft`. Found by decoding QuestieDB's baked
  data: `QuestieDB_Forever.toc` lines `## X-Npc-<id>-<field>: <base64 CBOR>` (field `S` = map of the
  string/number fields by key index: 1 name, 13 friendlyToFaction, 14 subName, 15 npcFlags; field `7` = spawns).
- **installer/** (new): see "Sharing with another PC". The partner's setup (public repo vs token) isn't decided yet.

## Earlier session's changes
- **RangeBeep**: "beep when target is X yards" with a typed number (default 30); ranges from the
  LibRangeCheck item list, 28 yd via follow range.
- **ProfCap** (new): cap notice, trainer waypoints from QuestieDB (`C_Map.SetUserWaypoint` + supertrack),
  rank-aware (Journeyman…Grand Master by current cap). Class trainer entry added via
  `Menu.ModifyMenu("MENU_UNIT_SELF", …)` (option `classTrainerMenu`, default on).
- **ChatFade**: new messages in the selected tab bring chat back (`chatFadeShowNew`, `chatFadeShowSecs`=5).
- **FishKey** (new): override bindings (`SetOverrideBindingClick` → secure macro button, then
  `INTERACTTARGET`), `SoftTargetInteract` temporarily 3; swaps back 0.5 s after the channel ends.
  Louder splash sets SFX volume to the slider %, mutes music/ambience, sound in background; original
  values kept in `P13TweaksDB.fishSavedSound` and restored 3 s after fishing / at next login.
  Master volume is deliberately **not** touched (user asked for that change to be reverted).
- **KillsToLevel**: running kill tally (`P13TweaksDB.killCounts["Name-Realm"] = {total, mobs}`), shown as
  "Mob ×N" under the "N more" text; total only in the window. Popup lasts ~4 s (2.4 shown + 1.6 fade).
  Bug fixed: option key `killTally` used to collide with the data table.
- **Removed**: Quest target key (`PriorityTarget.lua` and `Bindings.xml` deleted, toc lines removed,
  saved keys cleaned in Core). Needs a game restart.

## Open items / ideas offered, not done
1. Trainer matching uses English NPC titles from QuestieDB – unverified in game, English client only.
2. Class trainer: titles assumed "<Class> Trainer"; first lookup in a session scans all NPCs (brief hitch).
3. Fishing bite detection isn't possible for addons; louder splash is the workaround.
4. Offered: filter which chat messages bring chat back; a "line out" timer; show the game's own kill
   statistic (`GetStatistic`, only if Forever has achievements) in the kill window.

## Git
Everything committed and pushed at the end of the 2026-11-16 session (quest sharing, spell-ready chime,
trainer title fix, installer). Commit/push on "close"/"handover"; end messages with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

# P13Tweaks – Handoff (2026-11-17)

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

## 2026-11-17 – untested in game (all need a full restart: new file in the .toc)
- **Options window redesign** (`Options.lua`): tabbed sidebar + section headings, dark flat look.
  Tab icons are unverified on Forever (a missing one shows blank/green).
- **AggroRange** (new): target aggro gauge + chimes. Uses `ns.UnitDistanceBand` from RangeBeep
  (whose `CheckAt` now takes a unit and skips secret values).
- **MapSeamless**: dragging ~40 px past a zone map's edge hands over to the continent at the same
  zoom/spot (`CheckEdgePush`). Diagnosed from a debug log: the "stuck drag" was the zone edge.
  Unknown whether the drag continues through the map switch.
- **ProfCap**: "Mark closest Mailbox" in the portrait menu (`/p13 mail`), mailboxes from QuestieDB
  objects named "Mailbox".
- Fishing sounds question: same answer as below (SFX channel can't be split; `MuteSoundFile` offered).
- Aggro **nameplate** colouring was offered and deferred by the user ("not for now").

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
  The window has a sidebar of tabs (Map, Combat, Quests, Towns, Professions, Chat & keys), each with
  section headings. **A new option must be added to `LAYOUT` at the top of Options.lua** (tab, section);
  one that isn't listed still shows, in an "Other" tab. Last tab opened is saved as `optionsTab`.
- `Features/*.lua`: one feature per file, each registers its own options and commands.

## Features (load order in the .toc)
| File | What it does | Commands |
|---|---|---|
| MapCircle | ring shrinks onto you when the map opens | |
| MapSeamless | one seamless zoomable world map (continent ↔ zone handover) | |
| MapTerrain (+ MapTerrainData) | draws the game's minimap terrain tiles over Kalimdor / Eastern Kingdoms continent and zone maps (only tiles in view; textures on a frame inside `ScrollContainer.Child`, under the pins). Tile col = `32 - worldY/533.33`, row = `32 - worldX/533.33`; map corners from `C_Map.GetWorldPosFromMapPos(map, (0,0)/(1,1))`. **Forever can't load them by path, only by file ID** (tested 2026-11-16 with a `/p13 tiletest`, since removed) – IDs in `MapTerrainData.lua`, generated from the community listfile (`world/minimaps/{azeroth,kalimdor,2991}/mapCC_RR.blp`, key `col*64+row`, keyed by instance ID). **Zephras Isle** (Forever starter island, uiMap 2521/2665) is its own world, instance 2991 – its 72 tiles are in the listfile under folder `2991`. `/p13 mapinfo <name>` (kept for now) logs a map's instance + world bounds to `P13TweaksDB.mapInfoLog` – use it to add other Forever zones (Riverglades not checked yet). Hides `MapExplorationPinTemplate` overlays while on. Zone-name labels on continent maps. Options `mapTerrain` (+ opacity `mapTerrainAlpha`), `mapTerrainLabels`, `mapTerrainButton` (Terrain/Painted toggle button bottom-left of the map, shown only on maps with terrain). **Cave view** (option `mapCaveView`, button order 15): when the map is open on your own zone, `IsIndoors()` and the game has no separate map for the spot, the real `Minimap` is reparented into the `ScrollContainer`, sized to the picture's short side, zoom 0, over a dark backing frame; mouse wheel on the minimap (own `OnMouseWheel`, original script put back) zooms it. Its regions and NAMED child frames (compass ring, border, buttons) go alpha 0 meanwhile; unnamed children (addon pins) stay. Our own gold player arrow at its centre (the minimap's arrow doesn't come along), rotated by `GetPlayerFacing()` unless `rotateMinimap`. **Don't change the minimap mask**: an earlier version made it square and "restored" `Textures\\MinimapMask`, which broke the minimap on Forever – there's no getter for the original. Restored on map hide / going outside (parent, points, size, scale, strata, level, zoom, wheel, alphas). **No panning** – tried (bigger minimap in a `SetClipsChildren` frame, slid by dragging) and removed: the game doesn't clip the minimap, it spilled over the screen. Wheel = engine zoom steps, via an invisible wheel-catcher frame over the minimap. Button toggles for the current indoor visit. Buildings count as indoors too. Also MapMemory now skips its restore when the best map is a cave/dungeon map (type > Zone) | |
| MapMemory | map reopens where you left it | |
| MapMiddleClick + MapCenterKey | middle-click the map or its **Center** button (option `mapCenterButton`): centre on yourself and zoom in to ~800 yards across. Map buttons sit in a bottom-left row laid out by `ns:AddMapButton(button, order)` in Core.lua (terrain toggle 10, Center 20) | |
| InteractIcons | floating interact icons on nearby objects (soft-target CVars) | |
| RangeBeep | beep when target is **X yards** (typed; snapped to the nearest checkable range). Exports `ns.UnitDistanceBand(unit, maxYd)` | `range`, `dot` |
| AggroRange | gauge for a hostile, not-yet-fighting target: estimated aggro radius (20 yd ± 1 per level difference, 5–45) red, 5 yd warning yellow, your distance band white; chime near the edge, double chime inside. Draggable (`aggroRangePos`) | `aggro` |
| ProfCap | notice when a profession is at/near its cap; click a row = waypoint to nearest trainer; **right-click your own portrait → "Mark closest Class Trainer" / "Vendor (to sell)" / "Mailbox" (QuestieDB objects named "Mailbox", key `MAILBOX`, any faction) (nearest NPC with the vendor flag, key `VENDOR`; replaced "Repair (anvil)", which replaced "General Goods" – both still `/p13 repair` / `/p13 goods`) / "Auction House" (nearest auctioneer, key `AUCTION`) / "Weapon Master" (submenu per weapon; hardcoded `WEAPON_TEACHERS` by NPC name; pre-Cata clients only) / one "Mark closest <Profession> Trainer" per profession (icon, rank-aware via `GuideTo(p)`, list rebuilt each time the menu opens; only professions in `PROF_WORDS`)** | `prof [name\|reset]`, `trainer`, `goods`, `repair`, `sell`, `mail`, `ah`, `weapon [weapon]` |
| MinimapTownsfolk | bank / auction house / anvil (repair) icons on the minimap. Uses the game's own tracking (`MINIMAP_TRACKING_BANKER/AUCTIONEER/REPAIR`) when it exists (MoP); otherwise own pins via Questie's HereBeDragons-Pins, NPCs from ProfCap's QuestieDB scan (`ns.GetTownNpcs("BANK"/"AUCTION"/"REPAIR")`, matched on `LibQuestieDB.Enum.npcFlags` or title). Option `minimapTownsfolk`; `worldmapTownsfolk` = same icons on the world map, now drawn on our own layer in `ScrollContainer.Child` (like FlightPoints; no HBD – the HBD world pins weren't showing for the user), on zone/city maps only (each icon converted through world coords to whatever zone map is open, cached per map). World map needs only QuestieDB; own minimap pins still need Questie's HBD. Pin frames pooled. Errors reported in chat (pcall) | `townsfolk` (rebuild + counts) |
| FlightPoints | every flight point (own faction + neutral) on the world map, drawn on its own layer in `ScrollContainer.Child` (no Questie/HBD needed; positions converted through world coords so they show on the continent and its zone maps): white + green tick = unlocked, red + red cross = not unlocked, grey + ? = unknown (ready-check textures as badges, dark disc behind each icon). Positions from `C_TaxiMap.GetTaxiNodesForMap(continent)` (fallback: QuestieDB `FLIGHT` flight masters, no status). Known state learned on `TAXIMAP_OPENED` (`TaxiNodeGetType` CURRENT/REACHABLE) into `P13TweaksDB.knownFlights[char] = {names, continents}`; a continent counts as checked once its taxi map was seen. **On Forever only CURRENT/REACHABLE are yours; DISTANT = not unlocked** (verified from a log: a level-11 char's Everlook etc. are DISTANT with hidden buttons). Each taxi visit sets every listed node known/unknown, so stale entries self-correct. Option `flightPoints`. **Flight master's map** (classic `TaxiFrame`, option `flightPointsTaxi`): the taxi map lists every node of the continent; non-CURRENT/REACHABLE ones in our faction-filtered C_TaxiMap list get red-cross icons (name tooltip, not clickable) at `TaxiNodePosition` measured from the **top-left** of `TaxiRouteMap` (matches the game's `TaxiButton<i>` centres exactly). Druid-only "Nighthaven, Moonglade" isn't on the taxi map | `flights` |
| MapRoute | **double-click** the world map (two left mouse-downs ≤0.4 s, ≤12 px apart; uses the FIRST click's map + spot, since a continent click opens the zone) → route: straight walk vs walk → unlocked flight master → fly → walk (cost: distance / speed; speed = mount speed seen while `IsMounted()` per char in `P13TweaksDB.routeMountSpeed`, else 7 yd/s; flight 30 yd/s × 1.25 detour + 25 s). Flights from `C_TaxiMap.GetTaxiNodesForMap(continent)` filtered by `ns.IsFlightKnown` (FlightPoints), all assumed connected. Drawn with `CreateLine` on a layer in `ScrollContainer.Child` (dashed yellow walk, solid blue fly, raid-star destination); world↔map via each map's `GetWorldPosFromMapPos` corners. Game waypoint + supertrack on the next stop; re-plans on landing (`UnitOnTaxi` false) / `PLAYER_CONTROL_GAINED` / new zone; clears within 25 yd. "Clear route" map button (order 25). Option `mapRoute` | `route [clear]` |
| FishKey | one key (default `` ` ``) casts Fishing, then becomes Interact to reel in; optional louder splash with SFX % slider | `fish` |
| KillsToLevel | "N more" popup under the character after an XP kill + per-mob kill tally line; kill counts window with per-mob / all clear | `kills`, `killtest`, `killmove` |
| ChatFade | chat hidden until hovered; optional: show for N seconds when a message arrives | `chat` |
| ChatScroll | one wheel notch = one line; Shift = top/bottom, Ctrl = page | |
| SpellReady | chime when a typed spell (default "Skysight", comma list, item names too) comes off cooldown. On cooldown events it sets a `C_Timer` for the ready moment; GCD (≤1.5 s) ignored; only chimes after it has seen the spell cooling. Sound: auction house bell ding (`SOUNDKIT.AUCTION_WINDOW_OPEN`). Option `spellReady` + `spellReadyNames` | `ready` |
| QuestShare | teammates' quests + objective progress, only for group members who also run P13Tweaks (the game exposes no one else's quest log). Addon messages, prefix `P13Q`, on PARTY/RAID/INSTANCE_CHAT: `H^proto` hello (answered with a full list), `C` clear, `Q^id^state^title^+obj~-obj`, `R^id`, `X` sharing off. Own token-bucket send queue (8 burst, 1/1.1 s). Deltas from `QUEST_LOG_UPDATE` (1 s debounce); quests hidden under collapsed headers are kept, not removed. Window ("Ask again" re-sends hello) + tooltip line "Name: 3/10" when an objective text contains the hovered mob/item name. Options `questShare` (+ View), `questShareTooltips` | `quests`, `questsdemo` (pretend teammate = your own log, for testing solo) |
| FreeKeys | keys with nothing bound (`GetBindingAction(mod .. key, true)` empty) over a fixed list (main keyboard, F1-12, nav, numpad, mouse 3-5, wheel) × no modifier / Shift / Ctrl / Alt. Options window: info line with the free plain keys. (Asked while looking for a key for Scrap's "Toggle Item Under Mouse" binding – Scrap already has that.) | `freekeys` |
| QuestMobArrow | draggable on-screen arrow (`Media/Arrow.tga`, rotated `atan2(dY,dX) - GetPlayerFacing()`, green ahead → red behind; fake 3D: texture box is 64×32 so `SetRotation` draws it foreshortened like a shape on the ground – ahead points up the screen, behind points down; ring + shadow under it, up to 30 % smaller when behind; direction word "ahead / ahead, left / to your right / behind you" in the label) to the nearest **spawn point** of a creature still needed: each unfinished quest-log objective text is matched by name against QuestieDB `Quest.Get(id,"objectives")` groups [1] creatures, [5] kill credit, [3] items → `Item.Get(id,"npcDrops")`. Spawns via `Npc.Get(id,"spawns")` + ProfCap's `ns.LoadAreaMap`, cached as world points. Re-scan on `QUEST_LOG_UPDATE` (1 s debounce), nearest every 0.5 s (keeps the old spot unless the new one is 15 % / 10 yd closer – stops flip-flopping), arrow redrawn every frame with its angle eased toward the real one (`EASE` 18/s) for smooth turning; "around here" within 15 yd; arrow hidden when facing is unavailable. Needs QuestieDB. Option `questMobArrow`; position `questMobArrowPos`. First version – user will iterate | `mobarrow` (list targets + nearest) |

## Sharing with another PC
Git clone + junction only (no copy-based installer; it was removed in v0.3.6). Partner: install git, clone the repo
(private: sign in / read-only token), run `link.ps1` (finds WoW on any drive, replaces a plain copied folder with a
junction, idempotent). Updating = `git pull` + full WoW restart to see a new .toc version.
**Her PC can't run PowerShell scripts**, so (v0.5.1) there are double-click equivalents: `Link P13Tweaks.bat`
(same as link.ps1, pure cmd + `mklink /J`; tested on this PC) and `Update P13Tweaks.bat` (`git pull`). Both CRLF
(`.gitattributes`). Keep link.ps1 and the .bat in step if either changes.
Her PC may still hold leftovers from the removed installer: `%LOCALAPPDATA%\P13Tweaks\`, the Startup shortcut
"P13Tweaks updater" and the desktop "Update P13Tweaks" shortcut. They are harmless (the updater skips links) but can be deleted.

## Session 2026-11-17 (v0.2.0 to v0.3.2; the quest-log button was tried and replaced by a footer button in /p13) – untested in game, not yet committed
- **Versioning**: `## Version:` in BOTH .toc files is bumped on every update (user's request, so they and their
  friend can confirm matching builds). `ns.version` (Core.lua) reads it. Shown in the options title, in the quest
  window ("Versions:" line, red when different), via `/p13 version`, and exchanged in `H^proto^ver` / `C^ver`
  (old clients ignore the extra field); a one-time chat line appears when a teammate's version differs.
- **QuestShare**: window now has two views (button toggles, saved as `questShareView`): *By quest* (union of everyone's
  quests, each player's status: progress counts / ready / failed / "already completed" / "not started") and the old
  *By player*. New message `D^id` = "I finished that quest" (sent only for quest ids someone in the group has had, so
  "not started" vs "done" can be told apart). Clicking one of your quests, or "Share all", pushes it to the group with
  the game's own `QuestLogPushQuest` (2 s apart). New option `questShareAuto` (default off): `AcceptQuest()` on
  `QUEST_DETAIL` when the "npc" is a group member. Players without P13Tweaks are listed as "can't be shown".

## Session (2026-11-16, late) – committed at "handover"
Status per item: what the user reported in game. Everything else here is untested.
- **Flight master's map**: not-unlocked flight points as red-cross icons – **confirmed right**.
- **Zephras Isle terrain** (own world, instance 2991; tiles from the listfile) – added, not commented on.
- **MapRoute** (new): double-click route (walk / fly via unlocked flight points), star + dashed/blue lines,
  game waypoint + arrow, re-plan on landing. User fixes: removing the pin clears the route; the game's pin is
  hidden on the world map while ours is active (star only); double-click the star removes it.
  `C_Map.GetUserWaypoint().position:GetXY()` errors on Forever – read `.x`/`.y`.
- **MapOverlay** (new): see-through, click-through, follows you, chrome hidden, picture centred and scaled to
  fill the screen, 20 % opacity – user: "perfect" for chrome hiding; flicker fixed (game's `mapFade`).
- **Cave view** (in MapTerrain): borrowed minimap in the map window indoors – works; arrow + wheel zoom added;
  compass ring/+− buttons hidden; **mask must not be changed** (broke the minimap); panning tried and removed.
- **MapMemory**: no restore when the best map is a cave/dungeon map.
- **MinimapTownsfolk**: world map icons now on our own layer (HBD world pins weren't showing); no login nag.
- **ProfCap portrait menu**: "General Goods" → "Repair (anvil)" → now **"Vendor (to sell)"** (`VENDOR` key by
  NPC flag); `/p13 repair`, `/p13 sell`, `/p13 goods`.
- **QuestMobArrow** (new): arrow to the nearest spawn of a creature still needed for a quest – user: "nice";
  fake 3D (flattened), smoothed turning + no flip-flopping added after "jittery".
- **FreeKeys** (new): `/p13 freekeys` + info line in options (for binding Scrap's toggle; Scrap already
  has "Toggle Item Under Mouse").
- `/p13 mapinfo <name>` (MapTerrain) kept as a tool for adding other Forever maps' terrain.
- **Fishing map**: built and removed (see below). Riverglades terrain: check later (open item 7).

## Earlier this evening – terrain map
User-tested in game unless noted:
- **MapTerrain** (new): real minimap terrain on the world map – "looks pretty good". Button
  row bottom-left (Painted/Terrain toggle + Center). Path loading failed, file-ID loading works.
- **Center button** + middle-click now centre **and zoom in** (~800 yd view). Zoom feel not commented on yet.
- **FlightPoints** no longer needs Questie (own layer); badges (tick/cross/?) added. Bugs fixed: icons
  had no parent (local `pinLayer` declared after `GetPin` → nil global) so they were placed 1.25× off;
  `pos and pos:GetXY()` only kept x. Retired `zzOLD…` nodes filtered (one sits on Ratchet).
  **Last fix not yet confirmed in game.** After the commit: not-unlocked flight points on the flight
  master's map (first try mis-placed them – fixed from a debug log; **confirmed right in game**); MinimapTownsfolk no longer warns
  at login when Questie is off (only on option change / `/p13 townsfolk`) – **untested, uncommitted**.
- **MapSeamless**: zoom options' instant rebuild crashed on a fresh character (used WorldMapFrame's map
  instead of `sc.mapID`). **SpellReady**: secret cooldown values handled (item 6 below).
- Gotchas learned: Lua `a and f()` truncates multi-returns; a local must be declared above every function
  that uses it; read SavedVariables to get in-game debug output (user can't copy chat) – write a log
  table into `P13TweaksDB`, user `/reload`s, read `_forever_\WTF\Account\*\SavedVariables\P13Tweaks.lua`.
- **Removed (user: "does little to nothing")**: a fishing map (Fishing button, zone skill labels, find-fish box,
  catch learning) was built and deleted the same session, never committed. Its research is worth knowing: every
  WoW Forever fishing guide gives the Classic Era zone values unchanged (clean = min + 95), reported not confirmed;
  skill-ups come only from successful catches; Zephras Isle 1/25. Saved keys `fishMap`, `fishMapView`, `fishLog`
  are cleared in Core.
- Ideas not done: low-res overview images if fully-zoomed-out continent hitches; MinimapTownsfolk and trainer
  lookups still need Questie/QuestieDB (most alts have Questie disabled).

## Previous session (2026-11-16)
- **QuestShare** (new, multiplayer): see the table row above. Untested in game; `/p13 questsdemo` tests it solo.
- **SpellReady** (new): spell-ready chime (was uncommitted from the previous session).
- **ProfCap trainer titles**: Forever's Zephras Isle Fishing trainer Baelann Swiftcurrent is titled `<Fisher>`
  (Valanaar, 63.3 75.7) and was missed; fishing words are now `fishing`/`fisher`. Also First Aid
  `medic`/`physician`/`surgeon` and Leatherworking `leathercraft`. Found by decoding QuestieDB's baked
  data: `QuestieDB_Forever.toc` lines `## X-Npc-<id>-<field>: <base64 CBOR>` (field `S` = map of the
  string/number fields by key index: 1 name, 13 friendlyToFaction, 14 subName, 15 npcFlags; field `7` = spawns).
- (installer/ was removed later; see "Sharing with another PC".)

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
5. **TODO (user asked, later):** center the map on a teammate – e.g. the Center button (or a second
   button next to it) cycles through you and each party/raid member wherever they are
   (`C_Map.GetBestMapForUnit("party1")` etc., then the same pan + zoom as `CentreOnPlayer(true)`).
7. **Later:** check Riverglades' terrain once the user has been there. It's uiMap 2548 on Eastern
   Kingdoms (world 0, X -6467..-9700, Y -1892..-6742 → tiles cols 35-44, rows 44-50). All those tiles have
   listfile IDs, some very recent (>5,000,000), which may be retail pictures rather than Forever's.
   If it looks wrong in game, Forever uses its own tiles there and they need different IDs.
6. WoW Forever has "secret" values (e.g. spell cooldowns in combat; `issecretvalue`): addon code
   can't compare them. SpellReady now retries every second instead of erroring; watch for this
   elsewhere.

## Git
Everything committed and pushed at the end of the 2026-11-16 late session (routes, overlay, cave view,
quest enemy arrow, free keys, Zephras terrain, flight master map icons). Commit/push on "close"/"handover"; end messages with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

- **v0.3.x additions**: `Features/MinimapButton.lua` (round "P13" minimap button; left = options, right = `/p13 quests`,
  draggable, angle in `minimapButtonAngle`, option `minimapButton`). The /p13 window footer has a "Teammates' quests"
  button (calls `ns.commands.quests`). The quest-log "Teammates" button and its option were removed in 0.3.2.
- **installer/Link-P13Tweaks.ps1 + `Link P13Tweaks (git).bat`** (new): git-based setup so `git pull` updates the game.
  Installs git via winget if missing, clones to `%USERPROFILE%\P13Tweaks` (token from `$Token` or the older installer's
  copy; remote URL carries it), replaces the copied `AddOns\P13Tweaks` folder with a junction to the clone, and makes an
  "Update P13Tweaks" desktop shortcut that re-runs it (pull). Parse-checked only, not run. The old Update-P13Tweaks
  startup updater skips junctions, so it's harmless alongside.
- **v0.3.3**: each player's name shows their P13Tweaks version (`VerTag`, red when it differs from yours) in both quest views.
  "Ask again" now sends the hello, waits 6 s, and reports per group member: updated (N quests, version) / no answer /
  no P13Tweaks - in chat and as a "Last check" block at the top of the window. Members get a `heard` timestamp on any message.
- **v0.3.4**: by-quest view no longer lists a "You" row (or the old "Versions:" line) - only teammates; your own
  quests still appear as clickable titles. Link-P13Tweaks.ps1: fixed a bug where re-running it (desktop shortcut)
  threw "Failed" after pulling because it copied itself onto itself; the shortcut now runs the script from the clone
  (`%USERPROFILE%\P13Tweaks\installer\Link-P13Tweaks.ps1`) so pulls update it, and it logs the .toc version it finds.
- **v0.3.5**: `link.ps1` is now THE way to link a clone (auto-finds WoW on any drive, replaces a plain copied
  AddOns\P13Tweaks with the junction, idempotent, `-NoPause` for terminals). Removed the git-installer
  (`Link-P13Tweaks.ps1` + `.bat`) from v0.3.2-0.3.4. Partner setup is now: install git, `git clone` the repo, run link.ps1,
  then just `git pull` (+ full WoW restart to see a new .toc version). The older copy-based installer remains.
- **v0.3.7**: the version now lives in `Version.lua` (`ns.version`, loaded first in both .tocs) as well as `## Version:` in the
  .tocs - bump all three every update. Reason: `/reload` re-reads Lua but NOT the .toc, so a pull + `/reload` now shows the
  new version. Only adding a new file to the .toc (or changing Interface/SavedVariables) still needs a full game restart.
  Partner setup = clone on her Desktop + `link.ps1` once; afterwards `git pull` + `/reload`.
- **v0.4.0**: third quest-window view "side by side" (View button cycles by quest -> side by side -> by player; `questShareView`
  = quest/compare/player). One column per player (you first, version under each name), one row per quest, cell = count
  ("3/10", single objective) or percent, ready/done/failed/"-" (not started); furthest along = green, behind = amber; a
  "gap" column = max-min progress in %, rows where players differ sort first; "Show: diffs/all" button (`questShareDiffOnly`).
  The window widens to fit (`W` is now variable, `CMP_*` constants). Rows carry `.cells/.titleW/.nowrap`. Untested in game.
- **v0.4.1**: `/p13 questsdemo` now adds TWO pretend teammates (Demo Ann, Demo Bob) built from your own quest log with
  built-in differences (behind / quarter way / ready / not started / already done / two fake quests only they have / Bob on
  version 0.3.9), so the side-by-side view, gap column and version tags can be tried alone. Run it again to remove them.
- **v0.5.0 QuestWhere** (new file `Features/QuestWhere.lua`, in both .tocs - NEEDS A FULL GAME RESTART once): click a quest you
  don't have in the teammates' quests window (any of the 3 views) -> panel "How do I get this quest?": blockers (level, race/class
  bitmasks via `bit`, `exclusiveTo`, `parentQuest`, `requiredMinRep`), tree of `preQuestGroup` (all) / `preQuestSingle` (any one)
  with done / in your log / not done (depth <= 6), the next quest to start (`NextStep`), its givers from `startedBy`
  ({creatures},{objects},{items}) with nearest spawn (spawns {area={{x,y}}} + `ns.LoadAreaMap`), and a waypoint button.
  QuestieDB field names are in `QuestieDB/src/meta/questMeta.lua` (`[2]='startedBy'`, `[12]='preQuestGroup'`, ...). Exports from
  QuestShare: `ns.QuestCompleted`, `ns.HasQuest`; window rows carry `.guide = questId`. Option `questHow`; command `/p13 questhow <id>`.
  Untested in game; the pretend teammates' fake quests (9990001/2) have no QuestieDB record by design.
- **v0.5.1**: fixed "tap twice after /reload": `BuildWindow` left the new quests window shown, so the first `ToggleWindow`
  hid it. It now `Hide()`s at the end of the build (callers show it).
- **v0.5.2**: opening the quests window re-syncs with the group: `OnShow` sends the hello (teammates resend their lists)
  and schedules `SendFull` for mine, quietly, at most once per 10 s, only when sharing is on and you're grouped.
- **v0.5.3**: opening the quests window from the /p13 menu (footer "Teammates' quests" button and the "View" button next to
  "Share quests with my group") closes the /p13 window, only when the quests window actually opened.
- **v0.5.4**: "You" is never shown in the quests window: the side-by-side view no longer has a "You" column (teammates only; your
  own quests still make rows so you can see where everyone else is on them; colours/gap are among teammates).
- **v0.6.0**: fourth quests-window view "sync plan" (View button cycles quest -> side by side -> sync plan -> player;
  `questShareView` = quest/compare/plan/player). `BuildPlan`: sections "Share these" (you hold it, a teammate lacks it;
  click = `PushQuest`), "Get these" (only teammates hold it; click = QuestWhere panel), "Ask a teammate to share" (a teammate holds
  it, another lacks it, you don't hold it), "Catch up" (2+ holders at different progress, via `CompareCell` scores). Players who
  finished a quest count as neither holders nor lackers. "You" is only ever written lowercase inside sentences, never as a label.
- **v0.6.1**: the sync plan no longer suggests sharing a quest a teammate can't accept. New message `P^level^race^class^numQuests`
  (sent after `C` in `SendFull`, on level-up, and when my quest count changes); members get `.level/.race/.class/.numQuests`.
  `WhyNot(m, name, id)` (QuestShare) uses `ns.WhyCantTake(id, who)` (QuestWhere `Blockers(lib,id,who)`, now parametrised for
  a teammate: level, max level, race/class bitmask, exclusiveTo, parentQuest, preQuestGroup/Single) plus "quest log full".
  Teammates who can't take it go under "Can't be shared yet" with the reasons; "Share all" skips them too. Prerequisite /
  exclusive quest ids are tracked (`Track` + `ns.QuestRelated`) so everyone reports (D) whether they've finished them.
  Only applies to teammates on 0.6.1+ (they send P); older ones are assumed able. Range (they must be close) isn't checked.
- **v0.6.2**: teammate data now lands all at once. New message `E` (end of a full list; `SendFull` = C, P, all Q, D, E). On `C`
  the receiver collects that teammate's list in `incoming[who]` (live `members[who]` untouched, window shows the old data plus
  "Syncing with teammates..."); on `E` it marks complete, and when every list in progress is complete (`TryApply`) or after
  `SYNC_TIMEOUT` (12 s, for clients without `E`) all are swapped in together (`ApplyIncoming`) and the window refreshes once.
  Single deltas (Q/R/D/P outside a full list) still apply immediately. No protocol bump: old clients ignore `E`.
- **v0.6.3**: "Syncing with teammates..." now shows from the moment a resync is asked for (window opens, "Ask again", someone joins:
  `StartSync()` = 8 s window, `IsSyncing()`) until the lists land (`ApplyIncoming` clears it), not only after the first `C`
  arrives. The sync plan no longer says "Everyone is on the same quests" while syncing.
- **v0.6.4**: sync plan "Catch up": the quest is one line, then one indented line per player ("Ann 3/10 (behind)", "Bob 10/10 (ahead)")
  via `e.sub` in `Section`.
- **v0.6.5**: sync plan uses your own character name (class colour) instead of the word "you" (`myLabel`; `NameColor("player")`).
- **v0.6.6**: sync plan "Can't be shared yet": one line per quest, then one indented line per player with their reasons
  (your own name first when it's you), instead of repeating the quest on every line. Clicking the quest opens the how-to panel when you're the one blocked.
- **v0.7.0 MapDraw** (new file `Features/MapDraw.lua`, in both .tocs - needs a FULL GAME RESTART once): "Draw" button in the map button row
  (order 30; Undo 31 / Clear mine 32 appear while drawing). Draw mode puts a mouse `catcher` frame over `ScrollContainer`
  (level +90, right-click passes through via `SetPassThroughButtons` if present); left-drag samples `sc:GetNormalizedCursorPosition()`
  (0..1 map coords) every >= 0.005 apart, max 300 points. Lines are drawn in a layer under `sc.Child` exactly like MapRoute (scaled 1/canvasScale,
  pooled `CreateLine`s, redrawn when `version`/map/scale changes). Sharing: prefix `P13M`, `S^map^id^part^parts^RRGGBB^points` (points = 4 chars each,
  two 12-bit base-64 numbers; 50 points per message; own token bucket 4 burst, 1 per 1.5 s), `U^id` undo, `X` clear. Strokes carry the sender's class colour.
  Newcomers get my strokes resent (3 s after the roster changes); lines of people who leave are dropped. Options `mapDraw`, `mapDrawFade` (+ `mapDrawFadeMinutes`, default 5;
  last 30 s fade out). `/p13 mapdraw clear | demo` (demo = two pretend teammates' sine-wave lines on the open map). Untested in game.
  Note: normally LEFT-drag pans the map; while drawing it draws instead.
- **v0.7.1**: sync plan "Can't be shared yet": under each blocked player's line, a clickable "-> find: <quest>" line for every quest they'd have to
  finish first (prerequisites, the parent quest). `Blockers()` (QuestWhere) now returns `reasons, refs`; `ns.WhyCantTake` and `WhyNot` pass `refs` on;
  `ns.QuestName(id)` added. Clicking opens `ns.ShowQuestGuide(id, title, { forName = "Ann" })` = where that quest starts + waypoint, whatever
  your own progress on it is ("you've finished it yourself" / "it's in your log" are noted). Plan sub-lines may now be tables `{text, indent, guide, who}`.
- **v0.7.2**: map drawing - "Undo" and "Clear mine" now show whenever you have lines on the map (not only in draw mode):
  `UpdateButtons()` (called from `Changed()`); they hide again when your lines are gone/faded. `/p13 mapdraw clear all` also clears
  teammates' lines from your own map (and sends the clear for yours).
- **v0.7.3**: map drawing lines were visible only in the black border outside the map picture on the friend's PC (hidden behind the map's own
  layers). The draw layer is now `sc.Child` level + 25 (was +16; route +18, flight points +20). If lines are STILL hidden, parent the layer to the
  ScrollContainer / WorldMapFrame instead of `sc.Child` and convert coordinates (canvas scale + scroll) by hand.
- **v0.7.4**: map drawing lines still hidden on the game's PAINTED map (visible on the terrain map, where exploration pins are hidden). The draw layer
  is now raised dynamically (`RaiseLayer`): at most once a second it scans `sc.Child:GetChildren()` and sets the layer's strata to the highest found and
  its level to highest+1 (cap 9999). `/p13 mapdraw debug` prints the layer's level/strata, the canvas' child count / highest level / strata and how many
  lines were drawn - paste that if lines are still hidden (the next idea would be a host frame outside `sc.Child`).
- **v0.7.5**: hold Shift + left-drag draws on the map without pressing the Draw button. `MODIFIER_STATE_CHANGED` sets `shiftHeld`; `RefreshCatcher()`
  shows/enables the mouse catcher while `drawing or shiftHeld or a stroke is in progress`, so left-down goes to the catcher (no panning). The Draw button
  remains as the "sticky" mode. Shift+click on blank map has no default function that I know of (on pins it links/tracks), nothing in this addon uses it.
- **v0.7.6**: removed the map "Draw" button (hold Shift + left-drag is the only way to draw; Undo / Clear mine still appear while you have lines).
  Clicking one of your quests in the teammates' quests window now selects it in the game's own quest log (`SelectInGame`: `SelectQuestLogEntry` +
  `QuestLogFrame` on classic-style logs, `C_QuestLog.SetSelectedQuest` + `QuestMapFrame_OpenToQuestDetails` on map-based ones, plus
  `C_SuperTrack.SetSuperTrackedQuestID`); Shift-click shares it with the group instead (the "Share these" plan lines still share on a plain click).
  Quests of mine in the by-player view and the catch-up lines are clickable too. Untested in game.
- **v0.7.7**: removed the map "Center" button and its option `mapCenterButton` (middle-click centres; `ns.CentreMapOnPlayer` stays in MapCenterKey.lua for
  middle-click and the overlay). Saved keys `mapCenterButton`/`mapCenterKey` are cleared in Core.
- **v0.7.8**: bug - a teammate on an OLDER P13Tweaks (no `E` end-of-list marker, maybe no version) showed as "no P13Tweaks": their list sat in
  `incoming` until the 12 s timeout, but "Ask again" reported after 6 s. Fix: `CheckQuiet` marks a list complete after 3 s with no new message
  (`incoming[who].last`), "Ask again" now reports after 9 s, and its wording no longer claims "no P13Tweaks" (older versions without a version number are
  reported as updated + "older P13Tweaks"). A version from before quest sharing existed (or sharing off) is indistinguishable from no addon.
- **v0.8.0**: removed the map Overlay feature entirely (`Features/MapOverlay.lua` deleted, .toc entries, option `mapOverlay`/`mapOverlayAlpha`, the HANDOFF
  table row). Core clears its saved keys and, if a /reload had left the game's `mapFade` CVar switched off, restores it from `mapOverlaySavedFade`.
  `ns.CentreMapOnPlayer` stays for middle-click. The .toc lost a file: a full game restart is needed after pulling.
- **v0.8.1**: my own name appeared twice in the sync plan: my own addon messages come back to me, and `who == UnitName("player")` missed "Name-Realm"
  (connected realms), so I was added to `members` as a teammate. New `IsMe()` (strips the realm) is used for the self-check in `OnMessage`. New first line
  "Players: me, Ann, Bob" (`PlayersLine`, each name once, with version tags) at the top of the sync plan and the by-quest view.
- **v0.8.2**: `IsMe()` now also normalises (lowercase, no spaces/hyphens) and accepts "<my name><all or the start of my realm name>", for a user whose character
  showed up twice ("Skade" and "Skade Stormr"). Added `/p13 questsdebug` (prints UnitName / GetUnitName / realm and every stored teammate key, flagging any that
  IsMe matches) - run it if a duplicate still appears. Not confirmed in game what the second name actually was.
- **v0.8.3**: clicking one of your quests in the quests window now TRACKS it (`SelectInGame`): `C_QuestLog.AddQuestWatch(id)` or classic `AddQuestWatch(index)`
  + `QuestWatch_Update`, and `C_SuperTrack.SetSuperTrackedQuestID(id)` where it exists; no quest log / map window is opened any more. Prints "Tracking: <quest>".
  (Classic Era caps the tracker at 5 quests, the game then refuses with its own message.)
- **v0.8.4**: sync that "kept updating/removing/adding" - suspected cause: names. `GroupNames()` (roster) used "Name-Realm" when `UnitName(unit)` returned a realm and
  plain "Name" when not (the realm loads late), so `OnRoster` saw people join/leave over and over (-> hello + full resend each time) and deleted members whose stored key
  was spelled differently. Now `GroupNames()` = plain names only; `KeyInGroup(key)` / `FindMember(name)` match a stored key however it was spelled (Norm = lowercase, no
  spaces/hyphens; "name" + realm or the start of it). MapDraw got the same fix. Your own name is shown as it looks to others (`myNetName`, learned from your own echoed
  messages, e.g. "Skade Stormr") via `MyName()`. `/p13 questsdebug` also prints counters (hellos sent, full lists sent/applied, newcomers seen, messages by kind) - if the
  refreshing continues, those numbers show which part repeats. Not verified in game.
- **v0.8.5**: map drawing - "Clear all" button (row order 33; shown whenever any line is on the map, whoever drew it): `ClearAll()` removes every stroke and sends
  `A`; receivers clear everything too and print who did it. `/p13 mapdraw clear all` does the same. Older clients ignore `A`.
- **v0.8.6**: sync plan "Catch up" also lists quests a teammate has FINISHED that you haven't (even ones nobody holds now: ids come from `seen` + the teammates' `done`
  sets). Each such quest shows every player: "finished" (blue) / progress (green/amber) / "not started". Click = track it if it's yours, else how-to-get-it panel.
  Only quests whose id is in `seen` (anything in anyone's log, plus prerequisite / exclusive / parent ids via `ns.QuestRelated`) can be known as finished - the "D" reports
  cover nothing else. Note exclusive-with quests a teammate chose instead may show up here too.
- **v0.9.0 faster sync** (QuestShare protocol): quests travel as compact records packed several to a message (`V^id:state:+3/10,-;...`, ~15-25 bytes each instead of a
  ~200-byte `Q` per quest). The wording (title, objective templates with `{c}` for the count) is sent once per quest as `T`, asked for with `N^id,id,...`, and cached in
  `P13TweaksDB.questText` (cap ~6000 entries); `BuildQuest` re-assembles "Boars slain: 3/10" from template + count, falling back to QuestieDB's name / "Quest <id>".
  `SendQuests()` uses `V` only when `Modern()` (every known member/incoming list has version >= 0.9.0, demos ignored), else the old `Q` per quest, so older clients keep working.
  A full list is held until its `E` arrives AND any unknown wording has been delivered (`incoming[who].need` / `gotE`; the 3 s quiet rule still ends a stuck wait; late `T`
  rebuilds stored quests via `RefreshQuestText`). Old `Q` messages also seed the cache. Typical full sync: ~2-3 messages instead of one per quest (first ever sync with a
  teammate still costs one `T` per quest you don't know). Stored quests carry `.raw` (the compact objective string). Fingerprint "skip if unchanged" NOT done yet.
  Untested with a real second player - `/p13 questsdebug` shows received message counts per kind (V/N/T/E...).
- **v0.9.1**: a quest change on one client reaches the others at about the same moment: my log is re-read 0.25 s after any of `MINE_EVENTS` (QUEST_LOG_UPDATE,
  UNIT_QUEST_LOG_CHANGED, QUEST_ACCEPTED, QUEST_REMOVED, QUEST_TURNED_IN, QUEST_WATCH_UPDATE; registered with pcall) - was 1 s after QUEST_LOG_UPDATE only - and only the changed
  quest goes out as a one-record `V` (or a `Q` for old clients). The receiving window refreshes ~0.2 s later. Live deltas still apply immediately (only full lists are held back).
- **v0.9.2 FollowClick** (new file `Features/FollowClick.lua`, in both .tocs - full game restart once): Shift + left-click a unit frame portrait follows that player. Sets the
  frame's secure attributes `shift-type1 = "macro"`, `shift-macrotext1 = "/follow mouseover"` on PartyMemberFrame1-4, CompactPartyFrameMember1-5, CompactRaidFrame1-40 and TargetFrame
  (out of combat only; `Apply()` retried on PLAYER_REGEN_ENABLED, re-run on GROUP_ROSTER_UPDATE because compact frames appear/disappear). Turning the option off removes only the attributes we set.
  Option `followClick` (Quests tab > Group). Relies on the game honouring modifier attributes on its own secure unit frames and on `mouseover` being the clicked unit - not verified in game.

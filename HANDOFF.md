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
| MapOverlay | **Overlay** map button (row order 40): `WorldMapFrame:SetAlpha(opacity)`, mouse + wheel switched off on the map and all its (non-protected) descendants, re-applied every 0.5 s (pins come and go), map buttons alpha 0, everything around the map picture alpha 0 (siblings at each level from `ScrollContainer` up to `WorldMapFrame`, plus `QuestMapFrame`), window scaled so the picture fills 96% of the screen and moved so the picture is centred (scale + anchors restored after; skipped in combat if protected), game's `mapFade` CVar off meanwhile (saved in `P13TweaksDB.mapOverlaySavedFade` for /reload safety) and any other `SetAlpha` on the map overridden in a post-hook, follows the player via `ns.CentreMapOnPlayer` (zoom in at start, pan every 0.5 s). Ends on map hide (restores mouse/alpha); if the hide came from `ToggleWorldMap` (M key) it re-opens the normal map (post-hook + `justEnded` flag; not in combat). Option `mapOverlay` + `mapOverlayAlpha` (default 20, was 60; one-time move via flag `mapOverlayAlpha20`) | |
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

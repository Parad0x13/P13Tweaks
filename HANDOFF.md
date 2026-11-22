# P13Tweaks – Handoff (2026-11-17)

## Handover summary (v0.14.4; newest changes are the last bullets of this file, v0.13.5 ... v0.14.4, all untested in game)
**NOTHING from v0.2.0 onward has been run in the game** (no Lua interpreter on this PC; every file was only read back, never executed). Expect load errors on first `/reload`:
turn on `/console scriptErrors 1` and fix what the popups say. Several new files need a full game restart (they were added to the .tocs): MapDraw, MapQuestHints, FollowClick,
TaggedMarks, QuestWhere, Version.lua. Version is kept in THREE places and bumped every update: `Version.lua`, and `## Version:` in both .tocs.
- **Deploy model**: git clone + `link.ps1` junction only (the old copy installer is gone). The friend does `git pull` + `/reload` (restart only when the .toc file list changed).
  Unrelated untracked/modified files in the folder (`Link P13Tweaks.bat`, `Update P13Tweaks.bat`, `.gitattributes`) are the user's own - never committed.
- **Quest sharing** (the big one, `Features/QuestShare.lua`, ~2100 lines, prefix `P13Q`): compact `V` records + cached wording (`T`/`N`), `F` fingerprints with automatic resync (`Y`),
  completed-quest history (`Z`/`K`), end-of-list marker `E`, `P` profile, `D` finished reports; "last known" ghosts of offline teammates; window views: by quest / side by side /
  sync plan / by player; click your quest = track, Shift-click = share; Shift-click a teammate's name = follow. Older versions are still supported (old `Q` format used while anyone is old).
  See the per-version bullets near the end of this file for design details (v0.2.0 ... v0.13.3).
- **Map**: MapDraw (Shift + drag draws, shared, Undo/Clear mine/Clear all), MapQuestHints (markers for quests teammates did / have; gold "?" for my quests they finished,
  at the work area, or the hand-in once I'm ready to turn in), minimap button; Center/Overlay/Draw buttons were removed on request.
- **Other new**: FollowClick (Shift-click portraits / the world / names), TaggedMarks (skull above enemies teammates target), QuestWhere ("how do I get this quest" panel + data helpers).
- **Ideas not built**: PartnerBags (share inventories; design discussed: item id x count lists + fingerprint, "who has X" tooltips, last-known copy), fingerprint-based skip of full lists
  is DONE; per-version compatibility shims could be dropped once both players are on 0.13+.
- **First things to check next session**: (1) any Lua error popups; (2) `/p13 questsdebug` counters while two clients are grouped (are hellos / full lists repeating?);
  (3) does "Synced" appear; (4) map markers (needs QuestieDB); (5) `/p13 followdebug`; (6) nameplates on for TaggedMarks.

## v0.27.1 - v0.27.14 (2026-11-21) - fly-to redesign + OPEN BUG: flicker at map-level switches
- **Fly-to is now ONE combined glide** (v0.27.1, user tested: "looks good"): `ns.FlyTo` just sets `fly = {tu,tv,finalS}`; each frame the goal is that point + final scale and pan and zoom ease together (the old zoom-out / glide / zoom-in phases are gone). Done when within 10 px and 2 % of the scale.
- **OPEN BUG (pinned, see below)**: for ~0.2 s at a map-level switch (e.g. area -> zone zooming out) the player arrow and nearby icons (an anvil) are drawn far too big / ghosted; on the painted map (terrain off) the map itself is drawn oddly instead.
  Happens with every other addon disabled. Ruled out with logs: pin size formula (arrow size x canvasScale is always 27 px, even at the end of `SwitchTo`), the game's player ping (`StartPlayerPing(2)` fires at every `SetMapID`, was suppressed, no change),
  hiding all `EnumerateAllPins` pins for 5 s (no visible change at all - maybe that iterator returns nothing here), terrain overlay, other addons.
  Leading idea: `SetMapID` resets the canvas (scale 0.6956 = game minimum, view centred, new canvas size) and the game lays tiles/pins out for that state in its own passes, a few frames after our `InstantPanAndZoom` write.
  **Next steps**: (1) in `/p13` > Map > Zooming untick "Tile-map zoom and pan" (then separately "Seamless map zoom"), /reload, repeat the zoom-out on the painted map - which one stops it?; (2) try making the game re-lay-out after our write.
- **Diagnostics still in the code (none fixed it; strip before the final version if wanted)**, all in `Features/MapSeamless.lua`: `ns.SyncPlayerPin` / `ns.SyncAllPins` (re-run the pins' `OnCanvasScaleChanged` after we write the scale; called from `SwitchTo` and every zoom frame in MapSheetZoom),
  a `StartPlayerPing` guard on the player pin (skips pings during/just after our switches), and `/p13 pindebug` (toggle; logs SetPinSize / SetPlayerPingScale / StartPlayerPing / SWITCH / MISMATCH lines around level switches into `P13TweaksDB.pinLog`, saved on /reload - read it from
  `.../_forever_/WTF/Account/<acct>/SavedVariables/P13Tweaks.lua`). Facts it taught: the player pin is a `GroupMembersPinTemplate` pin; the game sizes the arrow as ~27 / canvasScale and sets the ping scale to ~0.65 / canvasScale on every zoom step.
- `Options.lua`: `mapSheetZoom` ("Tile-map zoom and pan on the world map") was missing from LAYOUT (so it hid in the Other tab); now first in Map > Zooming. `mapSheet` (the tile-map window) is still unlisted (Other tab).
- Version is now `0.27.14` in `Version.lua` and both .tocs (the options window shows the .toc/loaded number; a full restart refreshes .toc metadata).

## v0.27.0 (2026-11-21) - MAP REWORK: tile-map zoom/pan takes over the real world map
**State when handed over**: the user tested most of this live and said the real-map zoom/pan is "significantly better" than at the start of the session. Still open: some Eastern Kingdoms terrain tiles look wrong,
and the fly-to (middle-click centring, v0.27.0) was written last and NOT yet tried. New files in both .tocs: `Features/MapSheet.lua`, `Features/MapSheetZoom.lua` (a FULL game restart is needed once).
Debug aid still on in the user's saved settings (`P13TweaksDB.mapDebug = true`): writes `mapDebugTrace` / `mapDebugLog` / `mapDebugTiles` to the SavedVariables file (read it from
`.../_forever_/WTF/Account/<acct>/SavedVariables/P13Tweaks.lua`; the user `/reload`s to flush it). Turn it off with `/run P13TweaksDB.mapDebug = false`.

**Why the rework**: the game's ScrollContainer fights any addon that moves the view. Traces showed it clamps the view to its own narrow limits (`sc.scrollXExtentsMin/Max`, `scrollYExtentsMin/Max`; at low zoom only about +-0.07 around the
centre) and pulls it toward (0.5,0.5) EVERY frame in its own OnUpdate; its wheel handler also moves the view before an addon hook can run. Wrapping `CalculateScrollExtents*` did nothing (never called while zooming).
Lesson learned the hard way: test switches set with `/run P13TweaksDB.xxx = true` PERSIST between sessions (`mapNoEdgeRoom` silently kept the whole edge-room fix off for several versions); MapSeamless now clears
`mapNoEdgeRoom/mapNoSteer/mapNoHold` at login. Never leave a persistent test switch as the only way to disable something.

**The design that works (MapSheetZoom.lua, option `mapSheetZoom`, default on)**: WE own the view. Our state (ownX/ownY/ownS = centre in 0-1 map coords + canvas scale) is written to the map EVERY frame in a
`sc:HookScript("OnUpdate")` (hooks run AFTER the game's own update, so our write is what's drawn): scale via `sc:InstantPanAndZoom(s, x, y, true)` (only when it changed), position via
`sc:SetNormalizedHorizontalScroll/VerticalScroll`, and `ns.WidenMapLimits` (MapSeamless `WidenLimits`: adds EDGE_ROOM = 0.5 to the game's limit fields right after the game recomputes them; it remembers what it wrote so it never adds twice).
- Wheel: `sc:SetScript("OnMouseWheel", OnWheel)` REPLACES the game's handler (original saved; switching the option off restores it, a /reload restores the MapSeamless hook). Smooth exponential zoom (STEP 1.3, SMOOTH 14), the spot under the cursor stays fixed.
- Drag: detected by us (button down on the map + cursor moved > 3 px, or the game's `IsPanning()`); the view follows the cursor with no limits. Hands off the game's targets while the button is down (resetting them made the game never notice the drag = "gobbled pans").
- Requests: we keep the game's `targetScrollX/Y/targetScale` equal to our own state; a target that differs is someone else's request (middle-click, nav bar...) and we glide there ourselves (PAN_SMOOTH 12). Map id changed (not by us) = `Adopt()` what the game shows.
- Overlays: after writing, calls `ns.RedrawMapDrawings()` (MapDraw) and `ns.RefreshMapTerrain(false)` in the same frame (their own updates ran before ours = one frame at the old zoom = flicker).
- Hooks other files use: `ns.sheetZoomActive()`, `ns.OnMapSwitch(old,new,oldScale,newScale)` (carry zoom state across a level switch), `ns.CancelSheetZoom()`, `ns.FlyTo(u,v,finalScale)`.
- **Fly-to (v0.27.0 design, SUPERSEDED in v0.27.1 by one combined pan+zoom glide - see the v0.27.1 section; the three phases below no longer exist)**: middle-click (MapCenterKey `FlyToPlayer`) converts the player's position onto the map being viewed (`ns.MapPoint`, any number of levels) and calls `ns.FlyTo`: close = one glide; far (more than 0.8 view widths) = phase 1 zoom out
  until the trip fits, phase 2 glide, phase 3 zoom in to the final scale (the middle-click close-up scale, or the old one). Wheel/drag cancel it; level switches convert the destination/zooms. Falls back to the old switch-map-then-glide when conversion fails.

**Map levels follow the view (MapSeamless `CheckMapLevels`, runs after our frame step)**: zone/continent switching is no longer wheel-driven. (1) view 10 % wider than the whole map (`ParentScaleFromChild <= FitScale*0.9`) -> parent, same view;
(2) middle of the view over a neighbouring sibling map (`ChildAt(parent, ...)`) -> that map, same view; (3) on a continent/world, a child that fills the view (`scale >= fit*0.98`) -> that child. All via `SwitchTo`
(which widens limits, places the view exactly, refreshes terrain/drawings, and calls `ns.OnMapSwitch`). Deferred while dragging (`IsPanning`/left button down: a switch kills the game's drag) and while a glide is in flight
(target differs from the view and the view is moving). `ns.MapPoint(from,to,u,v)` converts a point between related maps (parent/child/sibling/ancestors, depth <= 3). The old wheel/CheckZoomIn/CheckEdgePush paths in MapSeamless
are still there but gated off while `mapSheetZoom` is on (they run if the user turns it off).

**Other changes this session**
- MapDraw: strokes are stored per map; `StrokeOn(s, mapID)` converts points onto the viewed map (cached in `s.conv`), so drawings survive level switches. Flicker fix via `ns.RedrawMapDrawings`.
- MapTerrain: draws tiles past the map's own edge (no trimming/0-1 culling, so zones show their neighbours); visible-range culling covers where the view is AND where it is heading (+2 tiles margin); flat deep-blue sea fill
  (`SEA_R/G/B`, a texture on the scroll area) behind the tiles; the game's painted map (detail layers, TiledBackground, MapExplorationPin pins) is hidden with sticky `SetAlpha` hooks (`paintedHidden`) while terrain is on
  (no flicker); `ns.RefreshMapTerrain` is called right after map switches. Debug: with `mapDebug` on, holding Shift over the map records the tile under the cursor into `P13TweaksDB.mapDebugTiles` (col,row,id).
- MapTerrainData: removed tiles whose file IDs belong to other game versions (they draw green or show wrong art): Eastern Kingdoms (world 0) kept only ids <= 400000 (839 tiles left, 373 removed); Kalimdor (world 1) kept only ids 207000-208999
  (1018 left, 87 removed - this also removed the 294xxx block that drew a bogus island east of Kalimdor). Zephras Isle (2991) untouched (72 tiles). Some Eastern Kingdoms tiles may still be wrong - use the Shift recorder.
- NEW `Features/MapSheet.lua`: a standalone "tilesheet" window (`/p13 sheet` or the "Tile map" button in the map's button row; option `mapSheet`): one continuous sheet of a whole continent (buttons: Eastern Kingdoms / Kalimdor / Zephras Isle),
  own smooth cursor-anchored zoom, drag pan, middle-click centres on you, player arrow, tile-under-cursor readout. This is the prototype whose feel the user loved; MapSheetZoom ports its maths onto the real map.
- Version bumped 0.20.0 -> 0.27.0 across `Version.lua` and both .tocs.

**Not done / ideas**
- Zone-level markers (quests etc.) only exist on the zone map you're in; panning over a border swaps them (game design). A bigger fix = draw our own marker layers on the sheet.
- MapSeamless still carries the old wheel-driven code (dead while mapSheetZoom is on): clean it up once the new zoom is final. The `mapDebug` code (traces, `mapDebugLog`) can be trimmed too.
- Fly-to tuning knobs: "far" threshold 0.8 view widths, zoom-out margin 1.5x, PAN_SMOOTH/SMOOTH. Untested.
- If the zoom ever misbehaves: `/p13` -> "Tile-map zoom and pan on the world map" off, then /reload.

## v0.20.0 (2026-11-20) - hunter low-ammo warning (untested in game; new file in both .tocs, needs a FULL restart)
- `Features/AmmoWarn.lua`, option `ammoWarn` + `ammoWarnLow` (toggleNumber, default on, threshold default 100), /p13 > Combat > Spells.
- Hunters only. Reads ammo slot 0 (`GetInventoryItemID/Count("player", 0)`); only warns if a bow/crossbow/gun is equipped in slot 18 (item class 2, subclass 2/18 = arrows, 3 = bullets). Clients without an ammo slot (MoP) never warn.
- Checks on `PLAYER_ENTERING_WORLD` and `UNIT_INVENTORY_CHANGED` (player). State machine ok/low/out: warns once when crossing to low, again at out; resets when back above the threshold. Warning = chat line + `UIErrorsFrame` text + raid-warning sound.
- `Version.lua` was out of sync (0.19.4 vs .toc 0.19.5); all three now 0.20.0.
- If it never warns: check script errors, `/dump GetInventoryItemID("player",0)`, and whether ammo count changes fire `UNIT_INVENTORY_CHANGED` on Forever (else add `BAG_UPDATE_DELAYED`).

## v0.19.5 (2026-11-20) - map drawing fade now OFF by default
- `mapDrawFade` default changed true -> false in `Features/MapDraw.lua` (lines stay until Clear mine / `/p13 mapdraw clear` / reload). Saved values are kept, so existing users may still have fading on. Untested in game.
- OPEN, unresolved: user reports map lines "draw themselves again" after being removed. Read all of MapDraw.lua and found no path that re-adds a removed line. Candidate causes: (1) Clear all (`A`) doesn't stop a teammate's queued stroke pieces / pending 3 s resend arriving afterwards; (2) pressing Clear mine while a stroke is still being drawn (`current` is no longer in `strokes` but still gets sent by EndStroke); (3) not MapDraw (demo lines, second client of same character, other addon). Asked the user how they remove lines, solo vs group, and whose colour; `/p13 mapdraw debug` after it recurs shows stroke count. No code changed for this.
- Not ours: a Questie taint error on `GetAuraDataByIndex` (Blizzard_MawBuffs via the objective tracker) was reported; fix is updating Questie or disabling its tracker.

## v0.19.0 - v0.19.4 (2026-11-19) - SkillLog + portrait menu icons (SkillLog ran once in game: one bug found and fixed)
- `Features/SkillLog.lua` (new file in both .tocs, needs a FULL restart). Options `skillLog` (toggleText, names default "Sinister Strike") and `skillBeacon` (off by default), in /p13 > Combat > Spells.
  `UNIT_SPELLCAST_SUCCEEDED` for "player" -> `P13TweaksDB.skillCounts[name]` + `P13TweaksDB.skillHistory` (last 500 `{time, name}`; written to SavedVariables only on /reload or logout).
  Beacon = 8x8 square at screen top-left, colour = total casts as RGB (r*65536+g*256+b), for an external program that samples that pixel (windowed/borderless only; read-only, no input to the game).
  `/p13 skills` prints totals. Sinister Strike has no cooldown (only GCD), so it logs casts, not "off cooldown".
- v0.19.1 fix: option key `skillLog` is the toggle (a boolean in P13TweaksDB) - the cast list had the same key and crashed `table.insert`; renamed to `skillHistory`. Lesson: option keys share P13TweaksDB with any data tables.
- v0.19.2-0.19.4 (`Features/ProfCap.lua`): portrait right-click menu got "Mark closest Bank" (`GuideToBank`, skillLine "BANK", `/p13 bank`) and icons on Auction House, Bank (minimap tracking textures) and Mailbox (`INV_Letter_15`). Untested in game; if an icon is missing use the fallbacks in MinimapTownsfolk.lua.
- Ideas raised, not built: per-character completed-quest recorder for "did any alt do quest X" (check `/dump C_QuestLog.IsQuestFlaggedCompletedOnAccount` on Forever first - unknown if it exists).

## v0.18.0 (2026-11-19) - CraftTime (untested in game; new file in both .tocs, needs a FULL restart)
- `Features/CraftTime.lua`, option `craftTime` (/p13 > Professions > Crafting): hovering the profession window's **Create All** button adds
  "N crafts x X sec = total" to the tooltip. N = `CraftingPage:GetCraftableCount()` (fallback `numAvailable`), X = recipe spell `castTime` via `C_Spell.GetSpellInfo`.
  Hooks `ProfessionsFrame.CraftingPage.CreateAllButton` after `Blizzard_Professions` loads (ADDON_LOADED / TRADE_SKILL_SHOW). No line if no cast time is reported.
- Assumes the field names above (Blizzard retail-style frame, which Forever uses per the cooking notes). If no line appears: check script errors, `/dump ProfessionsFrame.CraftingPage.CreateAllButton`.
- Committed together with the v0.19.x work. Trad0x work from the same session is described in Trad0x\HANDOFF.md (session 11).

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

## v0.16.0-0.17.1 (2026-11-19) - cooking profit (built, then REMOVED) + VendorSellAll
- **Current version 0.17.1. Needs a full game restart** (.toc list changed: CookingProfit.lua removed, VendorSellAll.lua added).
- **VendorSellAll** (`Features/VendorSellAll.lua`, option `vendorSellAll`, /p13 > Towns > Vendor): with a vendor window open, Ctrl + right-click a bag item sells every other
  stack of that itemID (<= 12 stacks in total, the vendor Buyback size), 0.08 s apart, via `GLOBAL_MOUSE_DOWN` + `C_Container.UseContainerItem`; the clicked stack is sold by the
  game's own right-click. Bag/slot of the button found via GetBagID/GetBag/parent ID. UNTESTED in game (bag addons like Bagnon may not expose bag/slot).
- **Cooking profit was built and then removed on request** (user moved it into TSM): v0.16.x scanned the Cooking window, listed recipes by vendor-sell minus ingredient cost, showed unlearned
  recipes with skill requirement. Findings worth keeping about THIS client (WoW Forever): it uses the MODERN profession API - no `TRADE_SKILL_UPDATE` event, no `GetNumTradeSkills`/`GetItemInfo`
  globals (use `C_Item.GetItemInfo`); recipes come from `C_TradeSkillUI.GetAllRecipeIDs/GetRecipeInfo/GetRecipeSchematic(id,false)` (`reagentSlotSchematics`, reagentType 1 = required);
  unlearned recipes are included (`info.learned == false`); `C_TooltipInfo.GetRecipeResultItem(id).lines` has "Requires Cooking (300)"; the profession frame is `ProfessionsFrame`.
  A new CreateFrame frame starts SHOWN (toggle bug). The file was deleted; saved keys cookRecipes/cookDebug/cookingProfit are cleared in Core.lua.
- Debug trick that worked: write diagnostic lines into `P13TweaksDB.<x>` then `/reload` and read `WTF/Account/*/SavedVariables/P13Tweaks.lua` (user cannot copy text out of chat).

## v0.15.0-0.15.3 – FishSession (untested in game; new file in both .tocs, needs a full restart)
- **OPEN ISSUE (handover)**: the popup did not appear on a real catch in 0.15.0/0.15.1; with 0.15.1 `/p13 fishsession debug` showed
  "slot cleared ... (not an item we saw)" (slots snapshot was empty). 0.15.2 snapshots at LOOT_READY and LOOT_OPENED and keeps a sticky
  `fishingLoot` flag until LOOT_CLOSED - NOT yet confirmed in game. Next step: user runs `/p13 fishsession debug` + a catch and reports the printed lines
  (fishing loot flag, slots in window, items remembered). If still empty, consider CHAT_MSG_LOOT as a fallback or GetLootSlotInfo link differences.
- v0.15.3: money shown as "1g 2s 33c" (coloured, zero parts dropped) and a "Per hour" line (shows "..." for the first minute).
- v0.15.1: 0.15.0 showed nothing in game, so detection now snapshots the loot slots at LOOT_OPENED (`IsFishingLoot()`) and counts a slot on LOOT_SLOT_CLEARED
  (no chat parsing). `/p13 fishsession test` shows a fake catch; `/p13 fishsession debug` prints what the events see.
- `Features/FishSession.lua`: popup on the first fishing catch:
  time since the cast that led to the catch, items caught, and worth = TSM `DBRegionSaleAvg` x count via `TSM_API` (optional dep `TradeSkillMaster`).
  Hover = item list. Closing the window (OnHide) ends the session; the next catch starts a new one. Option `fishSession` in /p13 > Professions > Fishing.
  Coin from fishing is ignored. Items with no TSM price are counted as "N without a price".

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
  Newcomers get my strokes resent (3 s after the roster changes); lines of people who leave are dropped. Options `mapDraw`, `mapDrawFade` (+ `mapDrawFadeMinutes`, default 5; fade itself off by default since v0.19.5;
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
- **v0.9.3**: Shift-click a teammate's name in the teammates' quests window follows them. `ApplyFollowButtons(list)` overlays pooled `SecureActionButtonTemplate` buttons
  (`shift-type1="macro"`, `shift-macrotext1="/follow <name>"`) on name areas collected during `RefreshWindow` (`e.follow` for the by-player headers, `c.follow` for cells: the side-by-side
  column headings and the "Players:" line, which is now cells, two names per row). Secure buttons can't be moved/changed in combat, so the call returns early then (they keep the last setup).
  `KeyInGroup(key)` now also returns the plain in-game name used in the macro. Uses option `followClick`. Not verified in game.
- **v0.10.0 MapQuestHints** (new file `Features/MapQuestHints.lua`, in both .tocs - full game restart once): "!" markers on the world map at the quest giver of quests teammates
  FINISHED (blue) that you haven't, plus (option `mapQuestHintsHas`) quests they currently HAVE (green); greyed when `ns.WhyCantTake` says you can't take it (tooltip shows the first reason).
  Data: `ns.QuestHints(includeHas)` (QuestShare: members' `done` sets / quests, minus my done/log) + `ns.QuestGiverPoints(id)` (QuestWhere: `startedBy` NPC/object spawns up to 12 points,
  faction-filtered, cached; returns points, requiredLevel). Positions for the shown map: same uiMap directly, else via `GetWorldPosFromMapPos` -> `GetMapPosFromWorldPos(cont, pos, mapID)`
  (only kept inside 0..1). Same-giver quests share a marker (grouped on a 1/150 grid). Marker layer sits in `sc.Child` and is raised above the map like MapDraw's (`RaiseLayer`, once a second).
  Hints recomputed every 3 s while the map is open. Options `mapQuestHints` (+ "Hints: on/off" map button, order 36) and `mapQuestHintsHas`. Click = user waypoint on the giver.
  Untested in game; the demo teammates' fake quests have no QuestieDB record so they can't show markers.
- **v0.10.1 last-known log**: teammates' quests are saved in `P13TweaksDB.lastKnown[name] = { t, version, level, race, class, numQuests, quests, done }` (references to the live tables, so they
  hold the last state when the teammate leaves; `RememberAll()` runs 5 s after data changes, when the group changes and after a list is applied; pruned to 30 days / 12 people by `PruneKnown`).
  `SyncGhosts()` (login, roster changes, list applied, 1 s after any message) puts saved teammates with no live data into `members` as `ghost = true` (`lastSeen`); a message from a ghost's name
  drops the ghost. Ghosts show in every view tagged "(last known 2 h ago)" / "(offline)" and count for Catch up, side-by-side, by-quest, by-player and the map hints; they are skipped by: Modern(),
  NeededBySomeone / Share all, the plan's `Others()` (share / ask / blocked), tooltips, follow buttons, "Ask again" (live only via `FindMember(name, true)`) and the group-leave prune. Option
  `questShareRemember` (off deletes the saved copies). Not tested with a real second player.
- **v0.10.0 MapQuestHints** also in this push-set: see its entry above.
- **v0.10.2**: the window's "Ask again" button is now **Sync**: "Syncing..." (disabled) while `IsSyncing()`, greyed "Synced" once a sync has finished and someone live is here
  (`synced` flag: set by `ApplyIncoming` or when `StartSync`'s 8 s window ends with live teammates; cleared by `StartSync`), otherwise "Sync" (enabled; runs `AskAgain`). Button = `win.askBtn`, updated in `RefreshWindow`.
- **v0.11.0 automatic sync (fingerprints)**: no manual sync button any more (replaced by a status text "Syncing..." / "Synced"; `/p13 sync` still exists as a fallback = old `AskAgain`).
  Every client announces `F^<hash>^<n>` (`Fingerprint()` = djb-style hash of the sorted `EncodeRecord`s of its quest log) after its quests change (1 s debounce), after finishing a full list,
  when the window opens and every 30 s (ticker). A receiver compares it with `Fingerprint(members[who].quests)` (`CheckFingerprint`); on mismatch it waits 3 s (a delta may be in
  flight) and, if still different, sends `Y^<name>` (at most once per 20 s per person) and the named client answers with a full list (C...E). `F` from someone I have no live copy of
  also triggers `Y`. Lists that came in the old `Q` format (`m.legacy`) are not compared. `m.sync` = true/false/nil feeds the status text. Opening the window no longer sends hello/full.
  Also: quests I hold that a teammate already finished are flagged ("- finished by Ann" in by-quest / by-player, "[done]" in side by side, a chat line when the "D" arrives, Catch up section).
- **v0.11.1**: FollowClick also follows a player you Shift+left-click in the 3D world: hidden `SecureActionButtonTemplate` "P13TweaksFollowWorld" (macro `/follow [@mouseover,help,nodead] mouseover`)
  bound with `SetOverrideBindingClick(worldBtn, true, "SHIFT-BUTTON1", ..., "LeftButton")` (replaces the default Shift+click on the world; option `followClickWorld`). Out of combat only.
  Party frames: also the newer `PartyFrame.MemberFrame1-4`. `/p13 followdebug` lists the unit frames found, whether Shift-click follow is set on each, and what Shift+left-click is bound to
  - use it if the portrait click doesn't work (the portrait path relies on the game honouring `shift-type1` on its own secure unit frames; not verified in game).
- **v0.12.0 TaggedMarks** (new file `Features/TaggedMarks.lua`, in both .tocs - full game restart once): a skull (raid-target icon 8) above the nameplate of every enemy a group member is TARGETING
  ("tagged" here = targeted; the game has no addon-readable "who hit first"). Every 0.2 s: collect `UnitGUID(partyNtarget / raidNtarget)` of alive attackable targets, then for each
  `C_NamePlate.GetNamePlates()` plate whose unit GUID matches, show a child frame anchored above `plate.UnitFrame`; hidden on `NAME_PLATE_UNIT_REMOVED` / when no longer targeted. Works with
  teammates who lack P13Tweaks. Needs enemy nameplates on in the game's settings. Option `taggedMarks` (Combat tab > Group). Not verified in game.
- **v0.13.0 completed-quests sync**: the old "D" reports only covered quests someone had in a log (`seen`), so a teammate's earlier quests were invisible. Now `F^hex^n^chash` carries a hash
  of everything the sender completed (`CompletedList()` = `C_QuestLog.GetAllCompletedQuestIDs` / `GetQuestsCompleted`; cached in `compCache`, dirtied when a quest leaves the log). A teammate whose
  `m.doneHash` differs sends `Z^<name>` (at most once a minute) and gets the list as `K^count^chash^part^parts^data` (sorted ids, gaps in base-64 varints, 200 chars a message; decoded into `m.done`,
  keeping single D reports). `DoneCandidates()` turns those (possibly thousands) into <= 40 "reasonable now" quests (QuestieDB `ns.QuestLevelInfo`: required level <= mine, quest level >= mine-10; at most 80 QuestieDB
  lookups per call, the rest next time) for the sync plan's Catch up section and the map hints (`ns.QuestHints` uses them + the old `seen` quests). The C list-start keeps a teammate's `done` set. Only 0.13.0+ clients
  send/answer these; older ones are unaffected. Untested in game.
- **v0.13.1**: map hints also mark quests I HAVE that a teammate already finished: a gold "?" (ActiveQuestIcon) at the quest's HAND-IN point (QuestieDB `finishedBy`; falls back to the giver) via new
  `ns.QuestFinisherPoints(id)` (QuestWhere: `PointsFor(id, field)` shared with `QuestGiverPoints`). `ns.QuestHints` adds those entries with `mine = true` (from `FinishedBy(id)`, no "can't take" reasons);
  the tooltip says "<names> already finished this - you have it (hand-in point)". Needs the teammate's finished data (K list on 0.13.0+, or a D report on older versions) and QuestieDB.
- **v0.13.2**: the gold "?" for my quests that a teammate finished is now placed where the quest's WORK is done, not at the hand-in: `ns.QuestObjectivePoints(id)` (QuestWhere) gathers spawn points
  from QuestieDB `objectives` ([1] creatures, [2] objects, [3] items -> `npcDrops`, [5] kill-credit groups; <= 14 creatures, <= 6 points each, <= 60 total; falls back to the hand-in
  point), and MapQuestHints collapses the points on the shown map to ONE marker at the middle of the busiest cluster (within 6 % of the map). `ns.QuestFinisherPoints` is still the fallback.
- **v0.13.3**: the gold "?" for my quests a teammate finished moves to the HAND-IN point once I've finished the quest's objectives (`q.state == 1` -> hint `.ready`, uses
  `ns.QuestFinisherPoints`; otherwise still the work area via `QuestObjectivePoints` with the cluster collapse). Tooltip says which. `convCache` keys carry the ready flag.
- **v0.13.5** (QuestShare): other classes' class quests are hidden from every teammate view, tooltips, "finished by" and map hints unless I can take them too (`ClassLocked(id)` /
  `Visible(m)`, from QuestieDB `requiredClasses`; no QuestieDB = nothing hidden).
- **v0.13.6**: "By quest" is ordered by quest chain: each quest is nested under the nearest listed prerequisite (`preQuestSingle/Group/parentQuest`, up to 8 steps back), indented with an arrow.
- **v0.13.7 / 0.13.9**: "By quest" teammate lines are Shift-click-follow targets; my own line ("You") is now listed under each quest.
- **v0.13.8** (FollowClick): world Shift-click no longer uses a SHIFT-BUTTON1 override binding (never fired on the 3D world); it hooks WorldFrame OnMouseDown/OnMouseUp and calls
  `FollowUnit(name)` (drag > 8 px = camera turn, ignored). UNTESTED - `FollowUnit` may be protected on this client.
- **v0.13.10**: `SyncGhosts` only shows saved ("last known") teammates who are still in the group (offline members); anyone who left is not shown. Saved data is kept on disk.
- **v0.14.0-0.14.3 BagMiddleSort** (new file, in both .tocs; option `bagMiddleSort`, Towns > Bags): middle-click a bag slot sorts. Slot hooks (OnMouseDown/Up) + a GLOBAL_MOUSE_UP
  fallback; default bags use `C_Container.SortBags`/`SortBags`; Bagnon/BagBrother frames (have `SortItems`, `IsCached`) call their own `SortItems()` (the cleanup button action).
  `/p13 bagdebug` shows what the mouse is over. UNTESTED in game; needs a full restart (new file).
- **v0.14.4 Profession trainer submenu** (Features/ProfCap.lua): the portrait menu now has one "Mark closest Profession Trainer" submenu listing ALL_PROFS (every profession; Inscription/Jewelcrafting gated by build; unlearned ones greyed but still work via SecondaryProf stand-in). `/p13 prof <name>` also searches ALL_PROFS. Untested in game.

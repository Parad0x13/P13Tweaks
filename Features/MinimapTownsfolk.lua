-- P13Tweaks feature: bankers, auctioneers and repair NPCs (anvil) on the minimap and world map.
-- (World map icons are always our own HereBeDragons pins, on every client.)
--
-- If the game's own minimap tracking menu has "Banker" / "Auctioneer" / "Repair" (MoP Classic does),
-- those are simply switched on. Otherwise (WoW Forever) we place our own icons:
-- NPC locations come from QuestieDB (via ProfCap.lua's NPC scan, matched on QuestieDB's
-- NPC flags (or English title), friendly to your faction) and the icons are drawn with
-- HereBeDragons-Pins, which Questie ships - so this part needs Questie + QuestieDB.
local ADDON_NAME, ns = ...

local KINDS = {
    {
        key = "BANK", label = "Banker", tracking = "MINIMAP_TRACKING_BANKER",
        icon = "Interface\\Minimap\\Tracking\\Banker", fallback = "Interface\\Icons\\INV_Misc_Bag_10_Blue",
    },
    {
        key = "AUCTION", label = "Auctioneer", tracking = "MINIMAP_TRACKING_AUCTIONEER",
        icon = "Interface\\Minimap\\Tracking\\Auctioneer", fallback = "Interface\\Icons\\INV_Misc_Coin_02",
    },
    {
        key = "REPAIR", label = "Repairs", tracking = "MINIMAP_TRACKING_REPAIR",
        icon = "Interface\\Minimap\\Tracking\\Repair", fallback = "Interface\\Icons\\Trade_BlackSmithing",
    },
}
local ICON_SIZE = 14
local REF = "P13TweaksTownsfolk"   -- our owner key in HereBeDragons-Pins

---------------------------------------------------------------------------
-- The game's own tracking menu
---------------------------------------------------------------------------

-- Tracking menu index for a localized name (e.g. MINIMAP_TRACKING_BANKER), plus whether it's on.
local function FindTracking(name)
    if not (name and C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo) then return end
    for i = 1, C_Minimap.GetNumTrackingTypes() do
        local a, _, c = C_Minimap.GetTrackingInfo(i)   -- newer clients: a table; older: name, texture, active
        local tName, active
        if type(a) == "table" then tName, active = a.name, a.active else tName, active = a, c end
        if tName == name then return i, active end
    end
end

---------------------------------------------------------------------------
-- Our own icons
---------------------------------------------------------------------------

-- Icon frames, kept and reused: pools.minimap / pools.worldmap = { frames, used }.
-- HereBeDragons-Pins re-parents and positions them; we only fill in look and tooltip.
local pools = { minimap = { frames = {}, used = 0 }, worldmap = { frames = {}, used = 0 } }
local WORLDMAP_SIZE = 16

local function PinOnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.npc.name, 1, 1, 1)
    GameTooltip:AddLine(self.npc.sub or self.kind.label)
    GameTooltip:Show()
end

local function GetPin(which, kind, npc)
    local pool = pools[which]
    pool.used = pool.used + 1
    local f = pool.frames[pool.used]
    if not f then
        f = CreateFrame("Frame", nil, which == "minimap" and Minimap or UIParent)
        local size = which == "minimap" and ICON_SIZE or WORLDMAP_SIZE
        f:SetSize(size, size)
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetAllPoints()
        f:EnableMouse(true)
        f:SetScript("OnEnter", PinOnEnter)
        f:SetScript("OnLeave", GameTooltip_Hide)
        pool.frames[pool.used] = f
    end
    if f.kind ~= kind then
        if f.tex:SetTexture(kind.icon) == false then f.tex:SetTexture(kind.fallback) end
    end
    f.kind, f.npc = kind, npc
    return f
end

local function ClearPins()
    local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    if HBDPins then
        HBDPins:RemoveAllMinimapIcons(REF)
        HBDPins:RemoveAllWorldMapIcons(REF)
    end
    for _, pool in pairs(pools) do
        for _, f in ipairs(pool.frames) do f:Hide() end
        pool.used = 0
    end
end

-- Counts from the last Update, for /p13 townsfolk.
local stats = { npcs = {}, mini = 0, world = 0, worldByMap = {} }

-- Pins for one kind of NPC on the minimap and/or the world map.
local function AddPins(kind, HBDPins, onMinimap, onWorldMap)
    local npcs = ns.GetTownNpcs and ns.GetTownNpcs(kind.key)
    if not npcs then return end
    stats.npcs[kind.key] = #npcs
    local areaMap = ns.LoadAreaMap()
    -- World map: only on the zone/city map the NPC is in, not on continent maps.
    local showFlag = HBD_PINS_WORLDMAP_SHOW_CURRENT
    for _, npc in ipairs(npcs) do
        for area, points in pairs(npc.spawns) do
            local uiMap = areaMap[area]
            if uiMap and uiMap ~= 0 then
                for _, pt in ipairs(points) do
                    local x, y = pt[1], pt[2]
                    if x and y and x >= 0 and y >= 0 then
                        if onMinimap then
                            HBDPins:AddMinimapIconMap(REF, GetPin("minimap", kind, npc), uiMap, x / 100, y / 100, false, false)
                            stats.mini = stats.mini + 1
                        end
                        if onWorldMap then
                            HBDPins:AddWorldMapIconMap(REF, GetPin("worldmap", kind, npc), uiMap, x / 100, y / 100, showFlag)
                            stats.world = stats.world + 1
                            stats.worldByMap[uiMap] = (stats.worldByMap[uiMap] or 0) + 1
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------

-- Questie's copy of HereBeDragons only redraws world map pins when the map changes zone or
-- something is removed, so pins added while the map is closed (e.g. at login) can be missed.
-- After adding, force one full redraw the next time the map is shown.
local worldDirty = false
local function RedrawWorldMap()
    local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    local provider = HBDPins and HBDPins.worldmapProvider
    if not (provider and WorldMapFrame and WorldMapFrame:IsShown()) then return end
    worldDirty = false
    provider.forceUpdate = true
    if provider.RefreshAllData then provider:RefreshAllData() end
end
if WorldMapFrame then
    WorldMapFrame:HookScript("OnShow", function() if worldDirty then RedrawWorldMap() end end)
end

local warned = false
local function Update()
    ClearPins()
    stats.npcs, stats.mini, stats.world = {}, 0, 0
    wipe(stats.worldByMap)
    local onMini = ns:Get("minimapTownsfolk") and true or false
    local onWorld = ns:Get("worldmapTownsfolk") and true or false
    local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    local haveData = HBDPins and ns.GetTownNpcs and ns.GetTownNpcs("BANK") ~= nil
    local needData = false
    for _, kind in ipairs(KINDS) do
        local idx, active = FindTracking(_G[kind.tracking])
        local ownMini = onMini
        if idx then
            -- The game can do the minimap itself: just flip its tracking switch.
            if (active and true or false) ~= onMini then C_Minimap.SetTracking(idx, onMini) end
            ownMini = false
        end
        if ownMini or onWorld then
            needData = true
            if haveData then AddPins(kind, HBDPins, ownMini, onWorld) end
        end
    end
    if needData and not haveData and not warned then
        warned = true
        ns:Print("Banker/auctioneer/repair map icons need Questie and QuestieDB loaded.")
    end
    if onWorld then
        worldDirty = true
        RedrawWorldMap()   -- right away if the map happens to be open
    end
end

-- Lua errors are hidden in some clients, so report ours in chat instead of failing silently.
local function SafeUpdate()
    local ok, err = pcall(Update)
    if not ok then ns:Print("|cffff5555Map icons error:|r " .. tostring(err)) end
    return ok
end

ns:RegisterCommand("townsfolk", "rebuild the banker/auctioneer/repair map icons and show what was found", function()
    if not SafeUpdate() then return end
    local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    ns:Print(("Map library (from Questie): %s. QuestieDB: %s."):format(
        HBDPins and "found" or "|cffff5555missing|r",
        (ns.GetTownNpcs and ns.GetTownNpcs("BANK")) and "found" or "|cffff5555missing|r"))
    ns:Print(("NPCs - bankers %d, auctioneers %d, repair %d. Icons placed - minimap %d, world map %d."):format(
        stats.npcs.BANK or 0, stats.npcs.AUCTION or 0, stats.npcs.REPAIR or 0, stats.mini, stats.world))
    local mapID = WorldMapFrame and WorldMapFrame:GetMapID()
    local here = C_Map.GetBestMapForUnit("player")
    local function name(id) local i = id and C_Map.GetMapInfo(id); return i and i.name or "?" end
    ns:Print(("World map is on %s (%s): %d icons there. You're in %s (%s): %d icons there."):format(
        name(mapID), tostring(mapID), stats.worldByMap[mapID] or 0,
        name(here), tostring(here), stats.worldByMap[here] or 0))
end)

ns:RegisterOption({
    key = "minimapTownsfolk",
    type = "toggle",
    label = "Show bankers, auctioneers and repairers on the minimap",
    tooltip = "Puts bank, auction house and anvil (repair) icons on the minimap where bankers, auctioneers and NPCs who repair gear stand (only ones friendly to your faction). Hover an icon for the NPC's name.\n\nUses the game's own minimap tracking when it has it; otherwise needs Questie and QuestieDB.",
    default = true,
    onChange = function() SafeUpdate() end,
})

ns:RegisterOption({
    key = "worldmapTownsfolk",
    type = "toggle",
    label = "...and on the world map",
    tooltip = "Same bank, auction house and anvil icons on the world map, on the zone or city map where each NPC stands (not on continent maps). Hover an icon for the NPC's name.\n\nNeeds Questie and QuestieDB.",
    default = true,
    onChange = function() SafeUpdate() end,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    -- A moment after login: the first NPC scan of QuestieDB takes a beat.
    C_Timer.After(3, SafeUpdate)
end)

-- P13Tweaks feature: bankers, auctioneers and repair NPCs (anvil) on the minimap and world map.
-- (World map icons are always our own, drawn on a layer inside the map, on every client.)
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
-- Minimap ones: HereBeDragons-Pins re-parents and positions them. World map ones: our own
-- layer inside the map (like FlightPoints.lua), so the world map needs no HereBeDragons.
local pools = { minimap = { frames = {}, used = 0 }, worldmap = { frames = {}, used = 0 } }
local WORLDMAP_SIZE = 16
local worldIcons = {}        -- { kind, npc, map, x, y } for the world map
local worldLayer, lastPlaced
local boundsCache = {}

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
        f = CreateFrame("Frame", nil, which == "minimap" and Minimap or worldLayer or UIParent)
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
        HBDPins:RemoveAllWorldMapIcons(REF)   -- (from older versions that used it)
    end
    for _, pool in pairs(pools) do
        for _, f in ipairs(pool.frames) do f:Hide() end
        pool.used = 0
    end
    wipe(worldIcons)
    lastPlaced = nil
end

---------------------------------------------------------------------------
-- World map drawing: each icon on its own zone/city map, and on any zone map it falls
-- inside (converted through world coordinates). Not on continent maps (far too many).
---------------------------------------------------------------------------

local function Bounds(mapID)
    if boundsCache[mapID] ~= nil then return boundsCache[mapID] end
    local r = false
    local info = C_Map.GetMapInfo(mapID)
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    if info and info.mapType and info.mapType >= zoneType and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local c1, tl = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local c2, br = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
        if c1 and c1 == c2 and tl and br then
            local top, left = tl:GetXY()
            local bottom, right = br:GetXY()
            if top ~= bottom and left ~= right then
                r = { inst = c1, top = top, left = left, bottom = bottom, right = right }
            end
        end
    end
    boundsCache[mapID] = r
    return r
end

-- Where icon i sits on map `mapID` (0-1), or nil.
local function PosOn(icon, mapID)
    if icon.map == mapID then return icon.x, icon.y end
    icon.cache = icon.cache or {}
    local c = icon.cache[mapID]
    if c ~= nil then
        if c then return c[1], c[2] end
        return
    end
    icon.cache[mapID] = false
    local from, to = Bounds(icon.map), Bounds(mapID)
    if not (from and to and from.inst == to.inst) then return end
    local X = from.top - icon.y * (from.top - from.bottom)
    local Y = from.left - icon.x * (from.left - from.right)
    local u, v = (to.left - Y) / (to.left - to.right), (to.top - X) / (to.top - to.bottom)
    if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
        icon.cache[mapID] = { u, v }
        return u, v
    end
end

local function PlaceWorldIcons(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (worldLayer and child and WorldMapFrame:IsShown()) then return end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    local sig = ("%d:%.5f:%.1f:%d"):format(mapID, scale, W, #worldIcons)
    if sig == lastPlaced and not force then return end
    lastPlaced = sig

    local pool = pools.worldmap
    for _, f in ipairs(pool.frames) do f:Hide() end
    pool.used = 0
    worldLayer:SetScale(1 / scale)
    worldLayer:SetSize(W * scale, H * scale)
    for _, icon in ipairs(worldIcons) do
        local u, v = PosOn(icon, mapID)
        if u then
            local f = GetPin("worldmap", icon.kind, icon.npc)
            if f:GetParent() ~= worldLayer then f:SetParent(worldLayer) end
            f:ClearAllPoints()
            f:SetPoint("CENTER", worldLayer, "TOPLEFT", u * W * scale, -v * H * scale)
            f:Show()
        end
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
    for _, npc in ipairs(npcs) do
        for area, points in pairs(npc.spawns) do
            local uiMap = areaMap[area]
            if uiMap and uiMap ~= 0 then
                for _, pt in ipairs(points) do
                    local x, y = pt[1], pt[2]
                    if x and y and x >= 0 and y >= 0 then
                        if onMinimap and HBDPins then
                            HBDPins:AddMinimapIconMap(REF, GetPin("minimap", kind, npc), uiMap, x / 100, y / 100, false, false)
                            stats.mini = stats.mini + 1
                        end
                        if onWorldMap then
                            -- drawn by our own world map layer (below), not HereBeDragons
                            table.insert(worldIcons, { kind = kind, npc = npc, map = uiMap, x = x / 100, y = y / 100 })
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

-- fromUser: the option was just changed or /p13 townsfolk was typed (not the login run)
local function Update(fromUser)
    ClearPins()
    stats.npcs, stats.mini, stats.world = {}, 0, 0
    wipe(stats.worldByMap)
    local onMini = ns:Get("minimapTownsfolk") and true or false
    local onWorld = ns:Get("worldmapTownsfolk") and true or false
    -- NPC locations need QuestieDB; our own minimap icons also need Questie's HereBeDragons.
    local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    local haveNpcs = ns.GetTownNpcs and ns.GetTownNpcs("BANK") ~= nil
    local missing = false
    for _, kind in ipairs(KINDS) do
        local idx, active = FindTracking(_G[kind.tracking])
        local ownMini = onMini
        if idx then
            -- The game can do the minimap itself: just flip its tracking switch.
            if (active and true or false) ~= onMini then C_Minimap.SetTracking(idx, onMini) end
            ownMini = false
        end
        if (ownMini and not HBDPins) or ((ownMini or onWorld) and not haveNpcs) then missing = true end
        if haveNpcs and (ownMini or onWorld) then AddPins(kind, HBDPins, ownMini, onWorld) end
    end
    -- Only said when you turn the option on or run /p13 townsfolk, not at every login
    -- (most characters run without Questie, and then this quietly does nothing).
    if missing and fromUser then
        ns:Print("Banker/auctioneer/repair icons need QuestieDB (for where the NPCs are), and the minimap ones also Questie, enabled on this character.")
    end
    PlaceWorldIcons(true)   -- right away if the map happens to be open
end

-- Lua errors are hidden in some clients, so report ours in chat instead of failing silently.
local function SafeUpdate(fromUser)
    local ok, err = pcall(Update, fromUser)
    if not ok then ns:Print("|cffff5555Map icons error:|r " .. tostring(err)) end
    return ok
end

ns:RegisterCommand("townsfolk", "rebuild the banker/auctioneer/repair map icons and show what was found", function()
    if not SafeUpdate(true) then return end
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
    onChange = function() SafeUpdate(true) end,
})

ns:RegisterOption({
    key = "worldmapTownsfolk",
    type = "toggle",
    label = "...and on the world map",
    tooltip = "Same bank, auction house and anvil icons on the world map, on the zone and city maps where each NPC stands (not on continent maps). Hover an icon for the NPC's name.\n\nNeeds QuestieDB (for where the NPCs are).",
    default = true,
    onChange = function() SafeUpdate(true) end,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    -- our world map layer, under the flight point icons
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if sc and sc.Child and sc.GetCanvasScale then
        worldLayer = CreateFrame("Frame", nil, sc.Child)
        worldLayer:SetPoint("TOPLEFT", sc.Child, "TOPLEFT")
        worldLayer:SetFrameLevel(sc.Child:GetFrameLevel() + 16)
        local poll = CreateFrame("Frame", nil, WorldMapFrame)
        poll:SetScript("OnUpdate", function() if ns.layersStamp ~= GetTime() then PlaceWorldIcons(false) end end)
        ns.AddMapLayerRefresh(function() PlaceWorldIcons(false) end)
        poll:SetScript("OnShow", function() PlaceWorldIcons(true) end)
    end
    -- A moment after login: the first NPC scan of QuestieDB takes a beat.
    C_Timer.After(3, function() SafeUpdate(false) end)
end)

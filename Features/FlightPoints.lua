-- P13Tweaks feature: every flight point on the world map, with the ones you haven't
-- unlocked yet marked in red.
--
-- Where they are: C_TaxiMap.GetTaxiNodesForMap(continent) lists every flight point on a
-- continent from anywhere. (If the client lacks it, flight masters from QuestieDB are shown
-- instead, without unlock status.)
-- Which you know: the game only tells us while a flight master's map is open. Each time it
-- opens we save, per character and continent, which flight points it offers
-- (P13TweaksDB.knownFlights). Until you've opened one on a continent, its points show grey
-- ("status unknown").
-- Icons are drawn with HereBeDragons-Pins from Questie, like MinimapTownsfolk.lua.
local ADDON_NAME, ns = ...

local REF = "P13TweaksFlights"
local SIZE = 16
local ICON = "Interface\\Minimap\\Tracking\\FlightMaster"
local ICON_FALLBACK = "Interface\\Icons\\Ability_Mount_Wyvern_01"
local COLORS = {
    known   = { 1, 1, 1 },
    locked  = { 1, 0.25, 0.25 },
    unknown = { 0.6, 0.6, 0.6 },
}

local function CharKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end

-- Saved knowledge for this character: { names = { [nodeName] = true }, continents = { [mapID] = true } }
local function Known()
    P13TweaksDB.knownFlights = P13TweaksDB.knownFlights or {}
    local k = P13TweaksDB.knownFlights[CharKey()]
    if not k then
        k = { names = {}, continents = {} }
        P13TweaksDB.knownFlights[CharKey()] = k
    end
    return k
end

-- Continent map ID that a map belongs to (walks up the parents).
local function ContinentOf(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    while info do
        if Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Continent then return info.mapID end
        if not info.parentMapID or info.parentMapID == 0 then return end
        info = C_Map.GetMapInfo(info.parentMapID)
    end
end

-- Every continent map ID the client knows.
local function Continents()
    local list, seen = {}, {}
    if C_Map.GetMapChildrenInfo and Enum and Enum.UIMapType then
        for _, root in ipairs({ 946, 947 }) do   -- Cosmic, Azeroth
            for _, c in ipairs(C_Map.GetMapChildrenInfo(root, Enum.UIMapType.Continent, true) or {}) do
                if not seen[c.mapID] then seen[c.mapID] = true; table.insert(list, c.mapID) end
            end
        end
    end
    if #list == 0 then list = { 1414, 1415 } end   -- Kalimdor, Eastern Kingdoms
    return list
end

-- Flight path faction numbers (Enum.FlightPathFaction): 0 neutral, 1 Horde, 2 Alliance.
local function MyFactionNumber()
    local f = UnitFactionGroup("player")
    return f == "Horde" and 1 or f == "Alliance" and 2 or nil
end

---------------------------------------------------------------------------
-- Learning what you know (flight master map open)
---------------------------------------------------------------------------

local Update   -- defined below

local function LearnFromTaxiMap()
    if not (NumTaxiNodes and TaxiNodeName and TaxiNodeGetType) then return end
    local cont = ContinentOf(C_Map.GetBestMapForUnit("player"))
    local k = Known()
    local learned = 0
    for i = 1, NumTaxiNodes() do
        local name, t = TaxiNodeName(i), TaxiNodeGetType(i)
        if name and (t == "CURRENT" or t == "REACHABLE") then
            if not k.names[name] then learned = learned + 1 end
            k.names[name] = true
        end
    end
    if cont then k.continents[cont] = true end
    if ns:Get("flightPoints") then Update() end
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

local frames, used = {}, 0

local function OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.name, 1, 1, 1)
    if self.state == "known" then
        GameTooltip:AddLine("Flight point - unlocked", 0.3, 1, 0.3)
    elseif self.state == "locked" then
        GameTooltip:AddLine("Flight point - not unlocked yet", 1, 0.3, 0.3)
        GameTooltip:AddLine("Talk to the flight master there to unlock it.", nil, nil, nil, true)
    else
        GameTooltip:AddLine("Flight point - status unknown", 0.7, 0.7, 0.7)
        GameTooltip:AddLine(self.hint or "Open any flight master's map on this continent once and P13Tweaks will remember which ones you have.", nil, nil, nil, true)
    end
    GameTooltip:Show()
end

local function GetPin(name, state, hint)
    used = used + 1
    local f = frames[used]
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(SIZE, SIZE)
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetAllPoints()
        if f.tex:SetTexture(ICON) == false then f.tex:SetTexture(ICON_FALLBACK) end
        f:EnableMouse(true)
        f:SetScript("OnEnter", OnEnter)
        f:SetScript("OnLeave", GameTooltip_Hide)
        frames[used] = f
    end
    f.name, f.state, f.hint = name, state, hint
    f.tex:SetVertexColor(unpack(COLORS[state]))
    f.tex:SetDesaturated(state == "unknown")
    -- Not-unlocked ones a bit bigger so they stand out.
    local s = state == "locked" and SIZE + 4 or SIZE
    f:SetSize(s, s)
    return f
end

local stats = { known = 0, locked = 0, unknown = 0, source = "none" }

-- Questie's HereBeDragons copy only redraws on zone change / removal: force one redraw
-- the next time the map is shown (same trick as MinimapTownsfolk.lua).
local dirty = false
local function Redraw()
    local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    local provider = HBDPins and HBDPins.worldmapProvider
    if not (provider and WorldMapFrame and WorldMapFrame:IsShown()) then return end
    dirty = false
    provider.forceUpdate = true
    if provider.RefreshAllData then provider:RefreshAllData() end
end
if WorldMapFrame then
    WorldMapFrame:HookScript("OnShow", function() if dirty then Redraw() end end)
end

Update = function()
    local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    if not HBDPins then return false, "Questie's map library (HereBeDragons) isn't loaded." end
    HBDPins:RemoveAllWorldMapIcons(REF)
    for _, f in ipairs(frames) do f:Hide() end
    used = 0
    stats.known, stats.locked, stats.unknown, stats.source = 0, 0, 0, "none"
    if not ns:Get("flightPoints") then Redraw(); return true end

    -- Shown on the continent map and on its zone maps.
    local showFlag = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2
    local k = Known()
    local myFaction = MyFactionNumber()

    if C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap then
        stats.source = "game"
        for _, cont in ipairs(Continents()) do
            for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(cont) or {}) do
                local fac = node.faction or 0
                if node.name and node.position and (fac == 0 or fac == myFaction) then
                    local state = k.names[node.name] and "known"
                        or (k.continents[cont] and "locked" or "unknown")
                    stats[state] = stats[state] + 1
                    HBDPins:AddWorldMapIconMap(REF, GetPin(node.name, state), cont,
                        node.position.x, node.position.y, showFlag)
                end
            end
        end
    end

    -- Fallback: flight masters from QuestieDB (no unlock status).
    if stats.known + stats.locked + stats.unknown == 0 and ns.GetTownNpcs and ns.GetTownNpcs("FLIGHT") then
        stats.source = "QuestieDB"
        local areaMap = ns.LoadAreaMap()
        for _, npc in ipairs(ns.GetTownNpcs("FLIGHT")) do
            for area, points in pairs(npc.spawns) do
                local uiMap = areaMap[area]
                if uiMap and uiMap ~= 0 then
                    for _, pt in ipairs(points) do
                        if pt[1] and pt[2] and pt[1] >= 0 and pt[2] >= 0 then
                            stats.unknown = stats.unknown + 1
                            HBDPins:AddWorldMapIconMap(REF,
                                GetPin(npc.name .. (npc.sub and (" <" .. npc.sub .. ">") or ""), "unknown",
                                    "This game version doesn't list flight points, so unlock status can't be shown."),
                                uiMap, pt[1] / 100, pt[2] / 100, showFlag)
                        end
                    end
                end
            end
        end
    end

    dirty = true
    Redraw()
    return true
end

local function SafeUpdate()
    local ok, res, msg = pcall(Update)
    if not ok then ns:Print("|cffff5555Flight point icons error:|r " .. tostring(res))
    elseif res == false and msg then ns:Print(msg) end
    return ok and res
end

ns:RegisterOption({
    key = "flightPoints",
    type = "toggle",
    label = "Show every flight point on the world map",
    tooltip = "Puts a flight point icon on the world map (continent and zone maps) for every flight point of your faction or neutral.\n\nWhite = unlocked, red (bigger) = not unlocked yet, grey = not known yet: the game only says which you have while a flight master's map is open, so open one once on each continent (per character) and it's remembered.\n\nNeeds Questie (for its map library).",
    default = true,
    onChange = function() SafeUpdate() end,
})

ns:RegisterCommand("flights", "rebuild the flight point map icons and show counts", function()
    if not SafeUpdate() then return end
    ns:Print(("Flight points (from %s): %d unlocked, |cffff4040%d not unlocked|r, %d unknown."):format(
        stats.source, stats.known, stats.locked, stats.unknown))
    if stats.unknown > 0 and stats.source == "game" then
        ns:Print("Grey = continents where you haven't opened a flight master's map on this character yet.")
    end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("TAXIMAP_OPENED")
events:SetScript("OnEvent", function(_, event)
    if event == "TAXIMAP_OPENED" then
        local ok, err = pcall(LearnFromTaxiMap)
        if not ok then ns:Print("|cffff5555Flight point icons error:|r " .. tostring(err)) end
    else
        C_Timer.After(4, SafeUpdate)
    end
end)

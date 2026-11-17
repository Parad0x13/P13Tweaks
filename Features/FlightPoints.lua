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
-- Icons are drawn straight onto the world map (no Questie needed; QuestieDB is only the
-- fallback source of positions on clients without C_TaxiMap).
local ADDON_NAME, ns = ...

local SIZE = 16
local ICON = "Interface\\Minimap\\Tracking\\FlightMaster"
local ICON_FALLBACK = "Interface\\Icons\\Ability_Mount_Wyvern_01"
local COLORS = {
    known   = { 1, 1, 1 },
    locked  = { 1, 0.25, 0.25 },
    unknown = { 0.6, 0.6, 0.6 },
}
-- Badge in the icon's lower-right corner: tick = unlocked, cross = not yet, ? = unknown
-- (the game's ready-check marks).
local BADGES = {
    known   = "Interface\\RaidFrame\\ReadyCheck-Ready",
    locked  = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    unknown = "Interface\\RaidFrame\\ReadyCheck-Waiting",
}
local BACKDROP = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"   -- round, for a dark disc

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

-- For MapRoute.lua: is this flight point (by name) one this character has unlocked?
function ns.IsFlightKnown(name)
    return Known().names[name] == true
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
    -- The flight map lists every flight point of the continent; only CURRENT / REACHABLE are
    -- yours (on Forever, DISTANT = not unlocked: hidden on the map). Set each one either way,
    -- so a wrong entry from before gets corrected.
    for i = 1, NumTaxiNodes() do
        local name, t = TaxiNodeName(i), TaxiNodeGetType(i)
        if name then
            local mine = (t == "CURRENT" or t == "REACHABLE") or nil
            if mine and not k.names[name] then learned = learned + 1 end
            k.names[name] = mine
        end
    end
    if cont then k.continents[cont] = true end
    if ns:Get("flightPoints") then Update() end
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

local frames, used = {}, 0
-- (declared up here, before GetPin uses it: declared further down, GetPin would see a nil
-- global and the icons would get no parent, i.e. the wrong scale and position)
local pinLayer, lastPlaced

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
        f = CreateFrame("Frame", nil, pinLayer)
        f:SetSize(SIZE, SIZE)
        -- dark disc behind the icon so it stands out on the terrain map
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetPoint("TOPLEFT", -2, 2)
        f.bg:SetPoint("BOTTOMRIGHT", 2, -2)
        f.bg:SetTexture(BACKDROP)
        f.bg:SetVertexColor(0, 0, 0, 0.6)
        f.tex = f:CreateTexture(nil, "ARTWORK")
        f.tex:SetAllPoints()
        if f.tex:SetTexture(ICON) == false then f.tex:SetTexture(ICON_FALLBACK) end
        f.badge = f:CreateTexture(nil, "OVERLAY")
        f.badge:SetSize(10, 10)
        f.badge:SetPoint("CENTER", f, "BOTTOMRIGHT", -2, 2)
        f:EnableMouse(true)
        f:SetScript("OnEnter", OnEnter)
        f:SetScript("OnLeave", GameTooltip_Hide)
        frames[used] = f
    end
    f.name, f.state, f.hint = name, state, hint
    f.tex:SetVertexColor(unpack(COLORS[state]))
    f.tex:SetDesaturated(state == "unknown")
    f.badge:SetTexture(BADGES[state])
    -- Not-unlocked ones a bit bigger so they stand out.
    local s = state == "locked" and SIZE + 4 or SIZE
    f:SetSize(s, s)
    return f
end

local stats = { known = 0, locked = 0, unknown = 0, source = "none" }

---------------------------------------------------------------------------
-- Drawing on the world map: our own layer inside the map's scroll child, scaled back so the
-- icons stay the same size on screen at any zoom. Each icon remembers the map it was given
-- on (f.map, f.x, f.y) and is converted through world coordinates to whatever map is open:
-- shown on its continent and that continent's zone maps.
---------------------------------------------------------------------------

local mapContinent = {}   -- mapID -> continent (instance) ID, or false

local function MapContinent(mapID)
    if mapContinent[mapID] == nil then
        local info = C_Map.GetMapInfo(mapID)
        local cont = false
        if info and Enum and Enum.UIMapType and info.mapType >= Enum.UIMapType.Continent
            and C_Map.GetWorldPosFromMapPos and CreateVector2D then
            cont = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.5, 0.5)) or false
        end
        mapContinent[mapID] = cont
    end
    return mapContinent[mapID]
end

-- Where icon f sits on map `mapID` (0-1), or nil if not on it.
local function PosOn(f, mapID)
    if f.map == mapID then return f.x, f.y end
    f.posCache = f.posCache or {}
    local c = f.posCache[mapID]
    if c == nil then
        c = false
        local here = MapContinent(mapID)
        if here and C_Map.GetMapPosFromWorldPos then
            local cont, world = C_Map.GetWorldPosFromMapPos(f.map, CreateVector2D(f.x, f.y))
            if cont == here and world then
                local _, pos = C_Map.GetMapPosFromWorldPos(cont, world, mapID)
                local x, y
                if pos then x, y = pos:GetXY() end   -- (not "pos and pos:GetXY()": that keeps only x)
                if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then c = { x, y } end
            end
        end
        f.posCache[mapID] = c
    end
    if c then return c[1], c[2] end
end

local function Place(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (pinLayer and child and WorldMapFrame:IsShown()) then return end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0 and H and H > 0) then return end
    local sig = ("%d:%.5f:%.1f:%.1f"):format(mapID, scale, W, H)
    if sig == lastPlaced and not force then return end
    lastPlaced = sig

    pinLayer:SetScale(1 / scale)
    pinLayer:SetSize(W * scale, H * scale)
    for i = 1, used do
        local f = frames[i]
        local x, y = PosOn(f, mapID)
        f:ClearAllPoints()
        if x then
            f:SetPoint("CENTER", pinLayer, "TOPLEFT", x * W * scale, -y * H * scale)
            f:Show()
        else
            f:Hide()
        end
    end
end

local function EnsureLayer()
    if pinLayer then return pinLayer end
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.Child and sc.GetCanvasScale) then return end
    pinLayer = CreateFrame("Frame", nil, sc.Child)
    pinLayer:SetPoint("TOPLEFT", sc.Child, "TOPLEFT")
    pinLayer:SetFrameLevel(sc.Child:GetFrameLevel() + 20)   -- above the terrain
    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function() Place(false) end)
    return pinLayer
end

-- Put icon f on map `mapID` at x, y (0-1).
local function AddIcon(f, mapID, x, y)
    f.map, f.x, f.y = mapID, x, y
    if f.posCache then wipe(f.posCache) end
end

Update = function()
    if not EnsureLayer() then return false, "The world map isn't ready yet." end
    for _, f in ipairs(frames) do f:Hide() end
    used = 0
    lastPlaced = nil
    stats.known, stats.locked, stats.unknown, stats.source = 0, 0, 0, "none"
    if not ns:Get("flightPoints") then return true end

    local k = Known()
    local myFaction = MyFactionNumber()

    if C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap then
        stats.source = "game"
        for _, cont in ipairs(Continents()) do
            for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(cont) or {}) do
                local fac = node.faction or 0
                -- ("zzOLD..." = retired flight points still in the game data, e.g. on top of Ratchet)
                if node.name and not node.name:match("^zz") and node.position
                    and (fac == 0 or fac == myFaction) then
                    local state = k.names[node.name] and "known"
                        or (k.continents[cont] and "locked" or "unknown")
                    stats[state] = stats[state] + 1
                    AddIcon(GetPin(node.name, state), cont, node.position.x, node.position.y)
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
                            AddIcon(GetPin(npc.name .. (npc.sub and (" <" .. npc.sub .. ">") or ""), "unknown",
                                    "This game version doesn't list flight points, so unlock status can't be shown."),
                                uiMap, pt[1] / 100, pt[2] / 100)
                        end
                    end
                end
            end
        end
    end

    Place(true)
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
    tooltip = "Puts a flight point icon on the world map (continent and zone maps) for every flight point of your faction or neutral.\n\nGreen tick = unlocked, red cross (red, bigger icon) = not unlocked yet, ? (grey icon) = not known yet: the game only says which you have while a flight master's map is open, so open one once on each continent (per character) and it's remembered.",
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

---------------------------------------------------------------------------
-- Not-yet-unlocked flight points on the flight master's map (classic "Flight Map" window).
-- The flight map lists every flight point of the continent but hides the ones you don't have
-- (type DISTANT on Forever, or NONE). TaxiNodePosition gives each one's spot: 0-1 from the
-- TOP-left of TaxiRouteMap (checked in game: matches the game's own TaxiButton centres).
-- Only flight points of your faction or neutral (from C_TaxiMap) are added.
---------------------------------------------------------------------------

local taxiPins, taxiUsed = {}, 0

local function TaxiPin(parent)
    taxiUsed = taxiUsed + 1
    local f = taxiPins[taxiUsed]
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f:SetSize(SIZE, SIZE)
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetPoint("TOPLEFT", -2, 2)
        f.bg:SetPoint("BOTTOMRIGHT", 2, -2)
        f.bg:SetTexture(BACKDROP)
        f.bg:SetVertexColor(0, 0, 0, 0.6)
        f.tex = f:CreateTexture(nil, "ARTWORK")
        f.tex:SetAllPoints()
        if f.tex:SetTexture(ICON) == false then f.tex:SetTexture(ICON_FALLBACK) end
        f.tex:SetVertexColor(unpack(COLORS.locked))
        f.badge = f:CreateTexture(nil, "OVERLAY")
        f.badge:SetSize(10, 10)
        f.badge:SetPoint("CENTER", f, "BOTTOMRIGHT", -2, 2)
        f.badge:SetTexture(BADGES.locked)
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.name, 1, 1, 1)
            GameTooltip:AddLine("Not unlocked yet", 1, 0.3, 0.3)
            GameTooltip:AddLine("Talk to the flight master there to unlock it, then you can fly here.", nil, nil, nil, true)
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", GameTooltip_Hide)
        taxiPins[taxiUsed] = f
    end
    f:SetFrameLevel(parent:GetFrameLevel() + 10)
    return f
end

local function DrawTaxiExtras()
    for _, f in ipairs(taxiPins) do f:Hide() end
    taxiUsed = 0
    if not (ns:Get("flightPoints") and ns:Get("flightPointsTaxi")) then return end
    local mapTex = _G.TaxiRouteMap or _G.TaxiMap   -- TaxiRouteMap is the one the buttons sit on
    local parent = _G.TaxiFrame
    if not (mapTex and parent and parent:IsShown() and NumTaxiNodes and TaxiNodePosition) then return end
    if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return end
    local cont = ContinentOf(C_Map.GetBestMapForUnit("player"))
    if not cont then return end

    -- Every flight point of yours/neutral on this continent: name -> continent position.
    local myFaction = MyFactionNumber()
    local all = {}
    for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(cont) or {}) do
        local fac = node.faction or 0
        if node.name and not node.name:match("^zz") and node.position and (fac == 0 or fac == myFaction) then
            all[node.name] = node.position
        end
    end

    local mW, mH = mapTex:GetWidth(), mapTex:GetHeight()
    if not (mW and mW > 0 and mH and mH > 0) then return end

    -- Every flight point on the continent is listed; the ones that aren't yours (DISTANT /
    -- NONE) the game hides. Put ours where its own button would be.
    for i = 1, NumTaxiNodes() do
        local name, t = TaxiNodeName(i), TaxiNodeGetType(i)
        local x, y = TaxiNodePosition(i)
        if name and all[name] and t ~= "CURRENT" and t ~= "REACHABLE"
            and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            local f = TaxiPin(parent)
            f.name = name
            f:ClearAllPoints()
            f:SetPoint("CENTER", mapTex, "TOPLEFT", x * mW, -y * mH)
            f:Show()
        end
    end
end

ns:RegisterOption({
    key = "flightPointsTaxi",
    type = "toggle",
    label = "Show not-unlocked flight points on the flight master's map",
    tooltip = "When you talk to a flight master, the flight points you haven't unlocked yet are added to its map as red icons with a red cross (hover for the name). You can't fly to them until you've been there - they're just so you know where they are.",
    default = true,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("TAXIMAP_OPENED")
events:SetScript("OnEvent", function(_, event)
    if event == "TAXIMAP_OPENED" then
        local ok, err = pcall(LearnFromTaxiMap)
        if not ok then ns:Print("|cffff5555Flight point icons error:|r " .. tostring(err)) end
        -- next frame, once the game has laid out its flight map
        C_Timer.After(0, function()
            local ok2, err2 = pcall(DrawTaxiExtras)
            if not ok2 then ns:Print("|cffff5555Flight map icons error:|r " .. tostring(err2)) end
        end)
    else
        C_Timer.After(4, SafeUpdate)
    end
end)

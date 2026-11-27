-- P13Tweaks feature: farming heatmap.
-- Click a mob in the farming tracker's "Best mobs" list (FarmSession.lua), or Map on an expedition in the Farming
-- tab (FarmLog.lua: all that expedition's kills), and every place you killed one is shown
-- as a heatmap on the world map and the minimap: kills are grouped into small squares of ground, each drawn as a
-- soft spot, yellow where you killed few and red where you killed the most. Click the line again to hide it.
-- Kill positions are world yards (UnitPosition: X = north, Y = west, plus the instance id), recorded by
-- FarmSession.lua in P13TweaksDB.farmSessionData.mobTypes[npcID].spots (saved expeditions: farmHistory[i].spots[npcID]);
-- what's shown is P13TweaksDB.farmHeatSel.
-- Minimap projection as in MapDrawMinimap.lua (its ns.MINIMAP_YARDS / ns.minimapIndoors are reused).
local ADDON_NAME, ns = ...

local BLOB = "Interface\\AddOns\\P13Tweaks\\Media\\Blob.tga"
local CELL = 30          -- yards: kills this close together are one spot
local SPOT_YD = 80       -- yards across one spot (bigger than a cell, so neighbouring spots blend)
local MIN_MAP_PX = 12    -- a spot is never smaller than this on screen on the world map (continent view)
local MIN_MINI_PX = 6
local EDGE = 0.97        -- spots are kept inside the minimap's round edge

local version = 0        -- goes up whenever the kills or the chosen mob change
local bins, binsVersion  -- { { inst =, X =, Y =, n = }, ... } for the chosen mob, and maxN
local maxN = 1

-- The saved expedition with this id (FarmSession.lua's P13TweaksDB.farmHistory).
local function Expedition(id)
    for _, e in ipairs(P13TweaksDB.farmHistory or {}) do if e.id == id then return e end end
end

-- The kill-position lists to show: { spots, spots, ... } for the selection in P13TweaksDB.farmHeatSel
-- ({ exp = expedition id or nil for the current run, npc = one kind of mob or nil for all }), or nil.
local function Spots()
    local sel = P13TweaksDB and P13TweaksDB.farmHeatSel
    if not sel then return nil end
    local byNpc = {}   -- npc -> spots
    if sel.exp then
        local e = Expedition(sel.exp)
        byNpc = e and e.spots or {}
    else
        local d = P13TweaksDB.farmSessionData
        for npc, m in pairs(d and d.mobTypes or {}) do byNpc[npc] = m.spots end
    end
    local lists = {}
    for npc, spots in pairs(byNpc) do
        if spots and (sel.npc == nil or sel.npc == npc) then table.insert(lists, spots) end
    end
    return #lists > 0 and lists or nil
end

-- The chosen kills grouped into CELL-yard squares (each placed at the average of its kills).
local function Bins()
    if bins and binsVersion == version then return bins end
    bins, binsVersion, maxN = {}, version, 1
    local byKey = {}
    local all = {}
    for _, list in ipairs(Spots() or {}) do
        for _, s in ipairs(list) do all[#all + 1] = s end
    end
    for _, s in ipairs(all) do
        local inst, X, Y = s[1], s[2], s[3]
        local key = inst .. ":" .. math.floor(X / CELL) .. ":" .. math.floor(Y / CELL)
        local b = byKey[key]
        if not b then
            b = { inst = inst, sx = 0, sy = 0, n = 0, pos = {} }
            byKey[key] = b
            table.insert(bins, b)
        end
        b.sx, b.sy, b.n = b.sx + X, b.sy + Y, b.n + 1
    end
    for _, b in ipairs(bins) do
        b.X, b.Y = b.sx / b.n, b.sy / b.n
        if b.n > maxN then maxN = b.n end
    end
    return bins
end

-- Yellow (few kills) -> orange -> red (most kills), more solid the hotter.
local function Heat(n)
    local t = maxN > 1 and (n - 1) / (maxN - 1) or 1
    return 1, 0.95 - 0.9 * t, 0.1 * (1 - t), 0.35 + 0.45 * t
end

---------------------------------------------------------------------------
-- World map: a layer in the map's scroll child (it zooms with the map, so spots cover the same ground)
---------------------------------------------------------------------------

local mapLayer, mapPool, mapUsed = nil, {}, 0
local mapSig = {}
local yardsAcross = {}   -- mapID -> yards from the left edge to the right edge of that map, or false

local function YardsAcross(mapID)
    if yardsAcross[mapID] == nil then
        local v = false
        if C_Map.GetWorldPosFromMapPos and CreateVector2D then
            local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
            local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
            if a and b then
                local _, ay = a:GetXY()
                local _, by = b:GetXY()
                if ay and by and math.abs(ay - by) > 1 then v = math.abs(ay - by) end
            end
        end
        yardsAcross[mapID] = v
    end
    return yardsAcross[mapID]
end

-- Where bin b sits on map `mapID` (0-1), or nil if not on it (cached per bin).
local function PosOn(b, mapID)
    local c = b.pos[mapID]
    if c == nil then
        c = false
        if C_Map.GetMapPosFromWorldPos and CreateVector2D then
            local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, b.inst, CreateVector2D(b.X, b.Y), mapID)
            if ok and pos then
                local x, y = pos:GetXY()
                if x and y and x >= -0.02 and x <= 1.02 and y >= -0.02 and y <= 1.02 then c = { x, y } end
            end
        end
        b.pos[mapID] = c
    end
    if c then return c[1], c[2] end
end

local function HideMap()
    for i = 1, mapUsed do mapPool[i]:Hide() end
    mapUsed = 0
end

local function PlaceMap(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (mapLayer and child and WorldMapFrame:IsShown()) then return end
    if not ns:Get("farmHeatMap") or not Spots() then
        if mapUsed > 0 then HideMap() end
        ns.SigSame(mapSig)   -- (forget the last placement, so turning it back on draws again)
        return
    end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0 and H and H > 0) then return end
    if ns.SigSame(mapSig, mapID, math.floor(scale * 1e5), math.floor(W * 10), math.floor(H * 10), version) and not force then
        return
    end
    local across = YardsAcross(mapID)
    local size = across and SPOT_YD / across * W or 0
    size = math.max(size, MIN_MAP_PX / scale)
    local n = 0
    for _, b in ipairs(Bins()) do
        local x, y = PosOn(b, mapID)
        if x then
            n = n + 1
            local t = mapPool[n]
            if not t then
                t = mapLayer:CreateTexture(nil, "OVERLAY")
                t:SetTexture(BLOB)
                mapPool[n] = t
            end
            t:SetSize(size, size)
            t:ClearAllPoints()
            t:SetPoint("CENTER", mapLayer, "TOPLEFT", x * W, -y * H)
            t:SetVertexColor(Heat(b.n))
            t:Show()
        end
    end
    for i = n + 1, mapUsed do mapPool[i]:Hide() end
    mapUsed = n
end

local function EnsureMapLayer()
    if mapLayer then return end
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.Child and sc.GetCanvasScale) then return end
    mapLayer = CreateFrame("Frame", nil, sc.Child)
    mapLayer:SetAllPoints(sc.Child)
    mapLayer:SetFrameLevel(sc.Child:GetFrameLevel() + 18)   -- above the terrain, under the icon layers (+20)
    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function() if ns.layersStamp ~= GetTime() then PlaceMap(false) end end)
    ns.AddMapLayerRefresh(function() PlaceMap(false) end)
end

---------------------------------------------------------------------------
-- Minimap
---------------------------------------------------------------------------

local miniLayer, miniPool, miniUsed = nil, {}, 0
local miniSig

local function HideMini()
    for i = 1, miniUsed do miniPool[i]:Hide() end
    miniUsed = 0
    miniSig = nil
end

local function UpdateMini()
    if not ns:Get("farmHeatMinimap") or not Spots() or not Minimap:IsVisible() then
        if miniUsed > 0 then HideMini() end
        return
    end
    local pX, pY, _, pInst = UnitPosition("player")
    if pX == nil or (issecretvalue and (issecretvalue(pX) or issecretvalue(pY))) then
        if miniUsed > 0 then HideMini() end
        return
    end
    local rotating = GetCVar("rotateMinimap") == "1"
    local facing = 0
    if rotating then
        facing = GetPlayerFacing and GetPlayerFacing() or 0
        if issecretvalue and issecretvalue(facing) then facing = 0 end
    end
    local zoom = Minimap:GetZoom() or 0
    local sizes = ns.MINIMAP_YARDS or { outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 } }
    local list = (ns.minimapIndoors and sizes.indoor) or sizes.outdoor
    local diameterYd = list[zoom] or list[#list]
    local halfPx = Minimap:GetWidth() / 2
    local sig = ("%.1f:%.1f:%.3f:%d:%s:%.1f:%d"):format(pX, pY, facing, zoom, tostring(ns.minimapIndoors), halfPx, version)
    if sig == miniSig then return end
    miniSig = sig

    local k = halfPx / (diameterYd / 2)   -- px per yard
    local R = halfPx * EDGE
    local cosF, sinF = math.cos(facing), math.sin(facing)
    local full = math.max(SPOT_YD * k, MIN_MINI_PX)
    local n = 0
    for _, b in ipairs(Bins()) do
        if b.inst == pInst then
            -- world offset from you -> minimap pixels (x right = east, y up = north)
            local x, y = -(b.Y - pY), b.X - pX
            if rotating then x, y = x * cosF + y * sinF, -x * sinF + y * cosF end
            x, y = x * k, y * k
            local dist = math.sqrt(x * x + y * y)
            -- frames aren't cut off by the round minimap, so a spot near the edge is shrunk to fit inside
            local size = math.min(full, 2 * (R - dist))
            if size >= MIN_MINI_PX * 0.5 then
                n = n + 1
                local t = miniPool[n]
                if not t then
                    t = miniLayer:CreateTexture(nil, "OVERLAY")
                    t:SetTexture(BLOB)
                    miniPool[n] = t
                end
                t:SetSize(size, size)
                t:ClearAllPoints()
                t:SetPoint("CENTER", miniLayer, "CENTER", x, y)
                t:SetVertexColor(Heat(b.n))
                t:Show()
            end
        end
    end
    for i = n + 1, miniUsed do miniPool[i]:Hide() end
    miniUsed = n
end

---------------------------------------------------------------------------
-- Hooks for FarmSession.lua, options
---------------------------------------------------------------------------

-- Called when a kill is recorded, the chosen mob changes or the session is reset.
function ns.FarmHeatChanged()
    version = version + 1
    miniSig = nil
    PlaceMap(true)
end

ns.FarmExpedition = Expedition

ns:RegisterOption({
    key = "farmHeatMap",
    type = "toggle",
    label = "Kill heatmap on the world map",
    tooltip = "Click a mob in the farming tracker's Best mobs list to see where you killed it: a heatmap, yellow where you killed a few and red where you killed the most. Click the line again to hide it.",
    default = true,
    onChange = function() ns.FarmHeatChanged() end,
})

ns:RegisterOption({
    key = "farmHeatMinimap",
    type = "toggle",
    label = "Kill heatmap on the minimap",
    tooltip = "The same kill heatmap around you on the minimap.",
    default = true,
    onChange = function() ns.FarmHeatChanged() end,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    EnsureMapLayer()
    if Minimap then
        miniLayer = CreateFrame("Frame", nil, Minimap)
        miniLayer:SetAllPoints(Minimap)
        miniLayer:SetFrameLevel(Minimap:GetFrameLevel() + 3)   -- (under the map drawings, +4)
        miniLayer:SetScript("OnUpdate", UpdateMini)
    end
end)

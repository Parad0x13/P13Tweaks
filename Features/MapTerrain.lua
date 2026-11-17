-- P13Tweaks feature: real terrain on the world map.
-- Draws the game's own minimap terrain tiles (the same pictures the minimap uses) over the
-- painted continent and zone maps of Kalimdor and the Eastern Kingdoms. Only tiles in view are
-- loaded, so it stays smooth while you zoom and pan. Pins (quests, flight points, trainers...)
-- sit on top as usual, since the tiles use the same world coordinates.
--
-- Tiles: one per 533.33-yard square of the world, a 64x64 grid per continent. Column =
-- 32 - worldY / 533.33, row = 32 - worldX / 533.33 (worldX/worldY as UnitPosition returns
-- them). Addons can't load them by file path on WoW Forever, only by file ID, so the IDs come
-- from MapTerrainData.lua.
local ADDON_NAME, ns = ...

local TILE_YARDS = 533.33333
local MAP_TYPE_CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
local MAP_TYPE_ZONE      = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3

local layer          -- holds our textures, inside the map's scroll child
local labelLayer     -- zone names on continent maps
local tilesInUse = {} -- key (continent * 4096 + col * 64 + row) -> texture
local spare = {}      -- released textures, for reuse
local labels = {}     -- pooled zone-name font strings
local boundsCache = {} -- mapID -> { continent, top, left, bottom, right } or false
local lastSig

local function Enabled() return ns:Get("mapTerrain") end

local function Alpha()
    local pct = tonumber(ns:Get("mapTerrainAlpha")) or 100
    return math.max(0, math.min(100, pct)) / 100
end

---------------------------------------------------------------------------
-- Which part of the world a map shows
---------------------------------------------------------------------------

-- World yards at the map's top-left and bottom-right corners, if it's a Kalimdor or
-- Eastern Kingdoms continent or zone map we have tiles for.
local function Bounds(mapID)
    if boundsCache[mapID] ~= nil then return boundsCache[mapID] end
    local result = false
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    if info and (info.mapType == MAP_TYPE_CONTINENT or info.mapType == MAP_TYPE_ZONE)
        and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local c1, tl = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local c2, br = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
        if c1 and c1 == c2 and ns.TerrainTiles and ns.TerrainTiles[c1] and tl and br then
            local top, left = tl:GetXY()
            local bottom, right = br:GetXY()
            if top ~= bottom and left ~= right then
                result = { continent = c1, top = top, left = left, bottom = bottom, right = right }
            end
        end
    end
    boundsCache[mapID] = result
    return result
end

---------------------------------------------------------------------------
-- Tiles
---------------------------------------------------------------------------

local function AcquireTexture()
    local t = table.remove(spare)
    if not t then
        t = layer:CreateTexture(nil, "BORDER")
    end
    t:Show()
    return t
end

local function ReleaseAll()
    for key, t in pairs(tilesInUse) do
        t:Hide()
        t:SetTexture(nil)
        table.insert(spare, t)
        tilesInUse[key] = nil
    end
end

-- The painted "explored area" pieces of zone maps draw above our tiles; hide them while the
-- terrain is showing (fully opaque terrain would just be covered by them).
local function SetExplorationShown(shown)
    if not WorldMapFrame.EnumeratePinsByTemplate then return end
    for pin in WorldMapFrame:EnumeratePinsByTemplate("MapExplorationPinTemplate") do
        pin:SetAlpha(shown and 1 or 0)
    end
end

local function DrawTiles(b, sc, child)
    local W, H = child:GetWidth(), child:GetHeight()
    local scale = sc:GetCanvasScale()
    if not (W and W > 0 and H and H > 0 and scale and scale > 0) then return end

    -- Map fraction (0-1) covered by one tile, and where tile column/row 0 would start.
    local du = TILE_YARDS / (b.left - b.right)
    local dv = TILE_YARDS / (b.top - b.bottom)
    local function U(col) return (b.left - (32 - col) * TILE_YARDS) / (b.left - b.right) end
    local function V(row) return (b.top - (32 - row) * TILE_YARDS) / (b.top - b.bottom) end

    -- Visible part of the map (map fractions), one tile of margin each side, kept on the map.
    local hs, vs = sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
    local halfU = sc:GetWidth() / scale / W / 2
    local halfV = sc:GetHeight() / scale / H / 2
    local uMin, uMax = math.max(0, hs - halfU - du), math.min(1, hs + halfU + du)
    local vMin, vMax = math.max(0, vs - halfV - dv), math.min(1, vs + halfV + dv)

    local cMin = math.max(0, math.floor((uMin - U(0)) / du))
    local cMax = math.min(63, math.floor((uMax - U(0)) / du))
    local rMin = math.max(0, math.floor((vMin - V(0)) / dv))
    local rMax = math.min(63, math.floor((vMax - V(0)) / dv))

    local ids = ns.TerrainTiles[b.continent]
    local alpha = Alpha()
    local pad = 1 / scale   -- one screen pixel of overlap hides hairline seams
    local wanted = {}
    for col = cMin, cMax do
        for row = rMin, rMax do
            local id = ids[col * 64 + row]
            -- keyed by continent too, so a continent <-> zone hand-over keeps the loaded tiles
            local key = b.continent * 4096 + col * 64 + row
            if id then
                -- tile rectangle on the map, trimmed to the map's own edges
                local u0, v0 = U(col), V(row)
                local x0, x1 = math.max(0, u0), math.min(1, u0 + du)
                local y0, y1 = math.max(0, v0), math.min(1, v0 + dv)
                if x1 > x0 and y1 > y0 then
                    wanted[key] = true
                    local t = tilesInUse[key]
                    if not t then
                        t = AcquireTexture()
                        t:SetTexture(id)
                        tilesInUse[key] = t
                    end
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", child, "TOPLEFT", x0 * W, -y0 * H)
                    t:SetSize((x1 - x0) * W + pad, (y1 - y0) * H + pad)
                    t:SetTexCoord((x0 - u0) / du, (x1 - u0) / du, (y0 - v0) / dv, (y1 - v0) / dv)
                    t:SetAlpha(alpha)
                end
            end
        end
    end
    for key, t in pairs(tilesInUse) do
        if not wanted[key] then
            t:Hide()
            t:SetTexture(nil)
            table.insert(spare, t)
            tilesInUse[key] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Zone names on continent maps (the painted continent map has them; the terrain doesn't)
---------------------------------------------------------------------------

local function HideLabels()
    for _, fs in ipairs(labels) do fs:Hide() end
end

local function DrawLabels(mapID, sc, child)
    HideLabels()
    local info = C_Map.GetMapInfo(mapID)
    if not (ns:Get("mapTerrainLabels") and info and info.mapType == MAP_TYPE_CONTINENT) then return end
    local scale = sc:GetCanvasScale()
    local W, H = child:GetWidth(), child:GetHeight()
    -- the label layer undoes the map's zoom, so names stay the same size on screen
    labelLayer:SetScale(1 / scale)
    labelLayer:SetSize(W * scale, H * scale)
    local n = 0
    for _, zone in ipairs(C_Map.GetMapChildrenInfo(mapID) or {}) do
        if zone.mapType == MAP_TYPE_ZONE and C_Map.GetMapRectOnMap then
            local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(zone.mapID, mapID)
            if minX and maxX > minX then
                n = n + 1
                local fs = labels[n]
                if not fs then
                    fs = labelLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                    fs:SetShadowOffset(1, -1)
                    fs:SetShadowColor(0, 0, 0, 1)
                    labels[n] = fs
                end
                fs:SetText(zone.name)
                fs:ClearAllPoints()
                fs:SetPoint("CENTER", labelLayer, "TOPLEFT",
                    (minX + maxX) / 2 * W * scale, -(minY + maxY) / 2 * H * scale)
                fs:Show()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Update while the map is open
---------------------------------------------------------------------------

local function Refresh(force)
    local sc = WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (child and layer) then return end
    local mapID = WorldMapFrame:GetMapID()
    local hasTerrain = mapID and Bounds(mapID)
    local b = Enabled() and hasTerrain

    local button = layer.toggleButton
    if button then
        local want = hasTerrain and ns:Get("mapTerrainButton") and true or false
        if button:IsShown() ~= want then button:SetShown(want) end  -- (re-lays the button row)
        button:SetText(Enabled() and "Painted map" or "Terrain map")
    end

    -- The first time a map opens its canvas has no size yet (scale comes out infinite):
    -- wait for a later frame instead of drawing with nonsense numbers.
    if b then
        local scale, W = sc:GetCanvasScale(), child:GetWidth()
        if not (scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    end

    local sig = b and ("%d:%.4f:%.4f:%.4f:%.0f:%.0f:%.2f:%s"):format(mapID, sc:GetCanvasScale(),
        sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll(),
        child:GetWidth(), child:GetHeight(), Alpha(), tostring(ns:Get("mapTerrainLabels"))) or "off"
    if sig == lastSig and not force then
        if b then SetExplorationShown(false) end  -- the map may have re-made them; cheap
        return
    end
    lastSig = sig

    if not b then
        ReleaseAll()
        HideLabels()
        SetExplorationShown(true)
        return
    end
    DrawTiles(b, sc, child)   -- re-places every tile and drops the ones out of view
    DrawLabels(mapID, sc, child)
    SetExplorationShown(false)
end

ns:RegisterOption({
    key = "mapTerrain",
    type = "toggleSlider",
    label = "Real terrain on the world map",
    before = "Real terrain on the world map, opacity",
    numberKey = "mapTerrainAlpha",
    numberDefault = 100,
    min = 10, max = 100, step = 5,
    tooltip = "Kalimdor and Eastern Kingdoms continent and zone maps show the real terrain (the same pictures the minimap uses) instead of the painted map, so zooming in and out looks like one detailed map. Lower the opacity to let the painted map show through. Open sea, dungeons and other continents keep the normal map.",
    default = true,
    onChange = function() Refresh(true) end,
})

ns:RegisterOption({
    key = "mapTerrainLabels",
    type = "toggle",
    label = "Zone names on the terrain continent map",
    tooltip = "With real terrain on, write each zone's name on the continent maps (the terrain pictures have no names of their own).",
    default = true,
    onChange = function() Refresh(true) end,
})

ns:RegisterOption({
    key = "mapTerrainButton",
    type = "toggle",
    label = "Terrain / painted map button on the world map",
    tooltip = "A small button in the bottom-left corner of Kalimdor and Eastern Kingdoms maps that switches between the real terrain and the game's painted map.",
    default = true,
    onChange = function() Refresh(true) end,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.Child and sc.GetCanvasScale and sc.GetNormalizedHorizontalScroll) then return end

    layer = CreateFrame("Frame", nil, sc.Child)
    layer:SetAllPoints(sc.Child)
    layer:SetFrameLevel(sc.Child:GetFrameLevel())  -- under the pins

    labelLayer = CreateFrame("Frame", nil, sc.Child)
    labelLayer:SetPoint("TOPLEFT", sc.Child, "TOPLEFT")
    labelLayer:SetFrameLevel(sc.Child:GetFrameLevel() + 1)

    -- first in the bottom-left button row (Core.lua), above the pins
    local button = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    button:SetSize(100, 22)
    button:SetFrameLevel(sc:GetFrameLevel() + 100)
    button:SetScript("OnClick", function()
        ns:Set("mapTerrain", not Enabled())   -- calls the option's onChange -> Refresh
        if ns.RefreshOptions then pcall(ns.RefreshOptions, ns) end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText(Enabled() and "Switch to the game's painted map" or "Switch to the real terrain map")
        GameTooltip:AddLine("Same as the option in /p13.", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:Hide()
    layer.toggleButton = button
    ns:AddMapButton(button, 10)

    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function() Refresh(false) end)
    poll:SetScript("OnShow", function() Refresh(true) end)
end)

-- P13Tweaks feature: real terrain on the world map.
-- Draws the game's own minimap terrain tiles (the same pictures the minimap uses) over the
-- painted continent and zone maps of Kalimdor and the Eastern Kingdoms, and Forever's
-- Zephras Isle (its own world, instance 2991). Any world in ns.TerrainTiles works. Only tiles in view are
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

local SEA_R, SEA_G, SEA_B = 0.04, 0.16, 0.25   -- the flat sea colour (deep blue)
local blackFill      -- the flat sea colour behind the terrain tiles, over the whole scroll area
local seaTop         -- the same colour INSIDE the tile layer, just under the tiles: covers whatever the game draws under them
local layer          -- holds our textures, inside the map's scroll child
local labelLayer     -- zone names on continent maps
local tilesInUse = {} -- key (continent * 4096 + col * 64 + row) -> texture
local spare = {}      -- released textures, for reuse
local labels = {}     -- pooled zone-name font strings
local boundsCache = {} -- mapID -> { continent, top, left, bottom, right } or false
local lastSig

local function Enabled() return ns:Get("mapTerrain") end

-- Black ocean (option mapTerrainBlackSea, default on) or the deep blue.
function ns.ApplySeaColour()
    if not blackFill then return end
    local r, g, b = SEA_R, SEA_G, SEA_B
    if ns:Get("mapTerrainBlackSea") then r, g, b = 0, 0, 0 end
    blackFill:SetColorTexture(r, g, b, 1)
    if seaTop then seaTop:SetColorTexture(r, g, b, 1) end
end

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

-- What to draw on a map, as segments. Each segment is one continent's tile grid plus the straight-line
-- change that turns "fraction of that continent's map" into "fraction of the map being viewed":
-- u = ox + (worldY - ...) * kx  (see DrawSegment).
--  * a continent or zone map: one segment, the identity change;
--  * the WORLD map (all of Azeroth): one segment per continent, placed where the game puts that
--    continent's map on the world map (C_Map.GetMapRectOnMap), so zooming out far enough keeps the terrain.
local MAP_TYPE_WORLD = Enum and Enum.UIMapType and Enum.UIMapType.World or 1
local segCache = {}

-- The continents of a world map: { { id = continent map, seg = segment in the world map's fractions } ... }
local function WorldContinents(worldID)
    local list = {}
    if not (C_Map.GetMapChildrenInfo and C_Map.GetMapRectOnMap) then return list end
    for _, kid in ipairs(C_Map.GetMapChildrenInfo(worldID) or {}) do
        if kid.mapType == MAP_TYPE_CONTINENT then
            local cb = Bounds(kid.mapID)
            local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(kid.mapID, worldID)
            if cb and minX and maxX and maxX > minX and maxY > minY then
                list[#list + 1] = { id = kid.mapID, minX = minX, maxX = maxX, minY = minY, maxY = maxY,
                    seg = { b = cb, ox = minX, oy = minY,
                        kx = (maxX - minX) / (cb.left - cb.right), ky = (maxY - minY) / (cb.top - cb.bottom) } }
            end
        end
    end
    return list
end

local function Segments(mapID)
    if segCache[mapID] ~= nil then return segCache[mapID] end
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    local b = Bounds(mapID)
    if b then
        local result = { { b = b, ox = 0, oy = 0, kx = 1 / (b.left - b.right), ky = 1 / (b.top - b.bottom) } }
        -- A continent map also draws the OTHER continents next to it (the view can be panned past the map's
        -- edge, and they were visible a moment ago on the world map): each placed through the world map.
        local parentID = info and info.mapType == MAP_TYPE_CONTINENT and info.parentMapID
        local pinfo = parentID and parentID ~= 0 and C_Map.GetMapInfo(parentID)
        if pinfo and pinfo.mapType == MAP_TYPE_WORLD and C_Map.GetMapRectOnMap then
            local mx, xx, my, xy = C_Map.GetMapRectOnMap(mapID, parentID)   -- this continent on the world map
            if mx and xx and xx > mx and xy > my then
                local cw, ch = xx - mx, xy - my
                for _, other in ipairs(WorldContinents(parentID)) do
                    if other.id ~= mapID then
                        local s = other.seg   -- (world fractions) -> (this continent's fractions)
                        result[#result + 1] = { b = s.b, ox = (s.ox - mx) / cw, oy = (s.oy - my) / ch,
                            kx = s.kx / cw, ky = s.ky / ch }
                    end
                end
            end
        end
        segCache[mapID] = result
        return result
    end
    if info and info.mapType == MAP_TYPE_WORLD then
        local list = {}
        for _, c in ipairs(WorldContinents(mapID)) do list[#list + 1] = c.seg end
        if #list > 0 then   -- (an empty answer may just be "not loaded yet": not cached)
            segCache[mapID] = list
            return list
        end
    end
    return false
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

-- While the terrain is showing, the game's own painted map stays hidden (its picture tiles,
-- the backdrop behind them, and the "explored area" pieces that draw above our tiles), so
-- only our tiles are left: no painted ocean or land around them, nothing extra past the map's
-- edge. Setting the transparency once per frame wasn't enough: the game resets it whenever it
-- rebuilds the map's layers and icons, and every reset showed for a frame (flicker). So each
-- of those frames gets a hook that keeps it at zero while we want it hidden.
local paintedHidden = false

local function Hide(f, hidden)
    if not (f and f.SetAlpha) then return end
    if not f.p13Hooked then
        f.p13Hooked = true
        hooksecurefunc(f, "SetAlpha", function(self, a)
            if paintedHidden and a ~= 0 then self:SetAlpha(0) end
        end)
    end
    f:SetAlpha(hidden and 0 or 1)
end

local function SetPaintedShown(shown)
    paintedHidden = not shown
    if blackFill then blackFill:SetShown(not shown) end
    if seaTop then seaTop:SetShown(not shown) end
    local pool = WorldMapFrame.detailLayerPool
    if pool and pool.EnumerateActive then
        for layerFrame in pool:EnumerateActive() do Hide(layerFrame, not shown) end
    end
    local child = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if child and child.TiledBackground then Hide(child.TiledBackground, not shown) end
    if WorldMapFrame.EnumeratePinsByTemplate then
        for pin in WorldMapFrame:EnumeratePinsByTemplate("MapExplorationPinTemplate") do Hide(pin, not shown) end
    end
end
-- Draw one continent's tiles (seg, see Segments) that are in view; marks what it uses in `wanted`.
local function DrawSegment(seg, wanted, sc, child, W, H, scale)
    local b = seg.b
    -- Map fraction (0-1) covered by one tile, and where tile column/row 0 would start.
    local du = TILE_YARDS * seg.kx
    local dv = TILE_YARDS * seg.ky
    local function U(col) return seg.ox + (b.left - (32 - col) * TILE_YARDS) * seg.kx end
    local function V(row) return seg.oy + (b.top - (32 - row) * TILE_YARDS) * seg.ky end

    -- Visible part of the map (map fractions), one tile of margin each side, kept on the map.
    -- Covers where the view is AND where its zoom/pan animation is heading (the zoomed-out
    -- end sees the most map), so a fast zoom or pan doesn't outrun the loaded tiles and leave
    -- holes in the picture. Two tiles of margin instead of one.
    local hs, vs = sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
    local hs2, vs2 = sc.targetScrollX or hs, sc.targetScrollY or vs
    local scale2 = sc.targetScale
    if not (scale2 and scale2 > 0 and scale2 < math.huge) then scale2 = scale end
    local lowScale = math.min(scale, scale2)
    local halfU = sc:GetWidth() / lowScale / W / 2
    local halfV = sc:GetHeight() / lowScale / H / 2
    local mu, mv = du * 2, dv * 2
    -- (not kept to the map's own 0-1 area: a zone's tiles continue past its border, so you can
    -- see and pan into the neighbouring zones; the tile grid itself (0-63) is the only limit)
    local uMin, uMax = math.min(hs, hs2) - halfU - mu, math.max(hs, hs2) + halfU + mu
    local vMin, vMax = math.min(vs, vs2) - halfV - mv, math.max(vs, vs2) + halfV + mv

    local cMin = math.max(0, math.floor((uMin - U(0)) / du))
    local cMax = math.min(63, math.floor((uMax - U(0)) / du))
    local rMin = math.max(0, math.floor((vMin - V(0)) / dv))
    local rMax = math.min(63, math.floor((vMax - V(0)) / dv))

    local ids = ns.TerrainTiles[b.continent]
    local alpha = Alpha()
    local pad = 1 / scale   -- one screen pixel of overlap hides hairline seams
    for col = cMin, cMax do
        for row = rMin, rMax do
            local id = ids[col * 64 + row]
            -- keyed by continent too, so a continent <-> zone hand-over keeps the loaded tiles
            local key = b.continent * 4096 + col * 64 + row
            if id then
                -- the whole tile, even where it hangs over the map's own edge
                local u0, v0 = U(col), V(row)
                local x0, x1 = u0, u0 + du
                local y0, y1 = v0, v0 + dv
                do
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
                    t:SetBlendMode("BLEND")   -- (a pooled tile may have been drawn differently before)
                    t:SetTexCoord((x0 - u0) / du, (x1 - u0) / du, (y0 - v0) / dv, (y1 - v0) / dv)
                    t:SetAlpha(alpha)
                end
            end
        end
    end
end

local function DrawTiles(segs, sc, child)
    local W, H = child:GetWidth(), child:GetHeight()
    local scale = sc:GetCanvasScale()
    if not (W and W > 0 and H and H > 0 and scale and scale > 0) then return end
    local wanted = {}
    for _, seg in ipairs(segs) do DrawSegment(seg, wanted, sc, child, W, H, scale) end
    for key, t in pairs(tilesInUse) do   -- drop what is out of view
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
    local onWorld = info and info.mapType == MAP_TYPE_WORLD   -- the whole-Azeroth map: name the continents
    if not (ns:Get("mapTerrainLabels") and info and (info.mapType == MAP_TYPE_CONTINENT or onWorld)) then return end
    local scale = sc:GetCanvasScale()
    local W, H = child:GetWidth(), child:GetHeight()
    -- the label layer undoes the map's zoom, so names stay the same size on screen
    labelLayer:SetScale(1 / scale)
    labelLayer:SetSize(W * scale, H * scale)
    local n = 0
    for _, zone in ipairs(C_Map.GetMapChildrenInfo(mapID) or {}) do
        if zone.mapType == (onWorld and MAP_TYPE_CONTINENT or MAP_TYPE_ZONE) and C_Map.GetMapRectOnMap
            and (not onWorld or Bounds(zone.mapID)) then   -- (on the world map only continents we draw)
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
    local hasTerrain = mapID and Segments(mapID)
    local b = Enabled() and hasTerrain   -- (the segments to draw)

    local button = layer.toggleButton
    if button then
        local want = hasTerrain and ns:Get("mapTerrainButton") and true or false
        if button:IsShown() ~= want then button:SetShown(want) end  -- (re-lays the button row)
        button:SetText(Enabled() and "Painted map" or "Terrain map")
    end

    -- The first time a map opens its canvas has no size yet (scale comes out infinite):
    -- wait for a later frame instead of drawing with nonsense numbers.
    if b then
        SetPaintedShown(false)   -- from the first frame, so the painted map never shows then vanishes
        local scale, W = sc:GetCanvasScale(), child:GetWidth()
        if not (scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    end

    local sig = b and ("%d:%.4f:%.4f:%.4f:%.0f:%.0f:%.2f:%s:%.4f:%.4f:%.4f"):format(mapID, sc:GetCanvasScale(),
        sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll(),
        child:GetWidth(), child:GetHeight(), Alpha(), tostring(ns:Get("mapTerrainLabels")),
        sc.targetScale or 0, sc.targetScrollX or 0, sc.targetScrollY or 0) or "off"
    if sig == lastSig and not force then
        if b then SetPaintedShown(false) end  -- the map may have re-made them; cheap
        return
    end
    lastSig = sig

    if not b then
        ReleaseAll()
        HideLabels()
        SetPaintedShown(true)
        return
    end
    DrawTiles(b, sc, child)   -- re-places every tile and drops the ones out of view
    DrawLabels(mapID, sc, child)
    SetPaintedShown(false)
end

-- Lets MapSeamless redraw straight after it switches maps, in the same frame, so the game's
-- own fog/art for the new map is never drawn for even one frame before we replace it.
ns.RefreshMapTerrain = Refresh

ns:RegisterOption({
    key = "mapTerrain",
    type = "toggleSlider",
    label = "Real terrain on the world map",
    before = "Real terrain on the world map, opacity",
    numberKey = "mapTerrainAlpha",
    numberDefault = 100,
    min = 10, max = 100, step = 5,
    tooltip = "Kalimdor and Eastern Kingdoms continent and zone maps, and the map of the whole world, show the real terrain (the same pictures the minimap uses) instead of the painted map, so zooming in and out looks like one detailed map. Lower the opacity to let the painted map show through. Dungeons and other worlds keep the normal map.",
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
    key = "mapTerrainBlackSea",
    type = "toggle",
    label = "Black ocean behind the terrain map",
    tooltip = "Where the real-terrain map has no tiles (open sea, past the edge of the world) the background is black. Untick for the deep blue sea colour.",
    default = true,
    onChange = function() ns.ApplySeaColour() end,
})


ns:RegisterOption({
    key = "mapTerrainButton",
    type = "toggle",
    label = "Terrain / painted map button on the world map",
    tooltip = "A small button in the bottom-left corner of Kalimdor and Eastern Kingdoms maps that switches between the real terrain and the game's painted map.",
    default = true,
    onChange = function() Refresh(true) end,
})

---------------------------------------------------------------------------
-- Cave view: in caves the world map only has the outdoor zone, but the minimap draws the
-- cave. While the map is open and you're indoors, borrow the real minimap: enlarge it over
-- the map picture (square, zoomed out), and put it back when the map closes or you go
-- outside. Mouse wheel over it zooms the minimap. The Cave view button switches back to the
-- normal map until you next go indoors. (Buildings count as indoors too.)
---------------------------------------------------------------------------

-- (No panning: the minimap only draws a circle centred on you, and the game doesn't clip it
-- at a frame's edges - a bigger, slid minimap spills over the rest of the screen. Tried and
-- removed.)
local cave = { active = false, userOff = false }
local caveBack, caveCatch, caveButton, caveArrow

-- Fit the borrowed minimap to the map window, centred.
local function CaveLayout()
    if not cave.active then return end
    local base = math.min(caveBack:GetWidth(), caveBack:GetHeight())
    if not base or base <= 0 then return end
    Minimap:SetSize(base, base)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", caveBack, "CENTER")
end

-- Wheel: through the minimap's own zoom steps.
local function CaveWheel(_, delta)
    local levels = Minimap:GetZoomLevels() or 1
    Minimap:SetZoom(math.max(0, math.min(levels - 1, Minimap:GetZoom() + delta)))
end

-- Indoors, on your own zone's map, and the game has no separate map for where you are.
local function CavePossible()
    if not (ns:Get("mapCaveView") and IsIndoors and IsIndoors()) then return false end
    local best = C_Map.GetBestMapForUnit("player")
    local info = best and C_Map.GetMapInfo(best)
    if not info or (info.mapType and info.mapType > MAP_TYPE_ZONE) then return false end
    return WorldMapFrame:GetMapID() == best
end

local function CaveStart()
    local sc = WorldMapFrame.ScrollContainer
    local m = Minimap
    if cave.active or not (m and sc) then return end
    cave.parent = m:GetParent()
    cave.points = {}
    for i = 1, m:GetNumPoints() do cave.points[i] = { m:GetPoint(i) } end
    cave.w, cave.h = m:GetSize()
    cave.scale, cave.zoom = m:GetScale(), m:GetZoom()
    cave.strata, cave.level = m:GetFrameStrata(), m:GetFrameLevel()
    cave.active = true

    caveBack:Show()
    m:SetParent(caveBack)
    m:SetScale(1)
    m:SetFrameStrata(sc:GetFrameStrata())
    m:SetFrameLevel(caveBack:GetFrameLevel() + 2)
    caveCatch:SetFrameLevel(caveBack:GetFrameLevel() + 20)   -- takes the wheel, above the minimap
    CaveLayout()
    -- (its round shape is left alone: the game won't say what mask it had, so it couldn't
    -- be put back reliably)
    m:SetZoom(0)                                        -- widest view of the cave
    -- hide the minimap's decorations (compass ring, border, zoom/tracking/mail buttons...):
    -- all its textures, and its NAMED child frames (the game's own); unnamed children are map
    -- icons from addons (herbs, our townsfolk icons...) and stay
    cave.hidden = {}
    for _, r in ipairs({ m:GetRegions() }) do
        cave.hidden[r] = r:GetAlpha()
        r:SetAlpha(0)
    end
    for _, c in ipairs({ m:GetChildren() }) do
        if c:GetName() and c ~= caveArrow then
            cave.hidden[c] = c:GetAlpha()
            c:SetAlpha(0)
        end
    end
    -- decorations that belong to the frame around the minimap but are attached to it (they
    -- move along): the +/- zoom buttons and friends. Also made unclickable meanwhile.
    cave.unclick = {}
    local extra = { _G.MinimapCompassTexture, _G.MinimapBorder, _G.MinimapBorderTop, _G.MinimapBackdrop,
        _G.MinimapZoomIn, _G.MinimapZoomOut, m.ZoomIn, m.ZoomOut,
        _G.MinimapCluster and _G.MinimapCluster.ZoomIn, _G.MinimapCluster and _G.MinimapCluster.ZoomOut }
    for i = 1, 10 do
        local obj = extra[i]
        if obj and obj.SetAlpha and cave.hidden[obj] == nil then
            cave.hidden[obj] = obj:GetAlpha()
            obj:SetAlpha(0)
            if obj.IsMouseEnabled and obj:IsMouseEnabled() then
                obj:EnableMouse(false)
                cave.unclick[obj] = true
            end
        end
    end
    -- the minimap's own player arrow doesn't come along; draw ours in the middle (you're
    -- always at the centre of the minimap)
    caveArrow:SetParent(m)
    caveArrow:ClearAllPoints()
    caveArrow:SetPoint("CENTER", m, "CENTER")
    caveArrow:SetFrameLevel(m:GetFrameLevel() + 5)
    caveArrow:Show()
end

local function CaveStop()
    if not cave.active then return end
    local m = Minimap
    m:SetParent(cave.parent)
    m:ClearAllPoints()
    for _, p in ipairs(cave.points) do m:SetPoint(unpack(p)) end
    m:SetScale(cave.scale)
    m:SetSize(cave.w, cave.h)
    m:SetFrameStrata(cave.strata)
    m:SetFrameLevel(cave.level)
    m:SetZoom(cave.zoom)
    for obj, a in pairs(cave.hidden or {}) do obj:SetAlpha(a) end
    for obj in pairs(cave.unclick or {}) do obj:EnableMouse(true) end
    cave.hidden, cave.unclick = nil, nil
    caveArrow:Hide()
    caveBack:Hide()
    cave.active = false
end

local function CaveCheck()
    local possible = WorldMapFrame:IsShown() and CavePossible()
    if not (IsIndoors and IsIndoors()) then cave.userOff = false end   -- outside again: reset
    local want = possible and not cave.userOff
    if want and not cave.active then CaveStart() elseif not want and cave.active then CaveStop() end
    if caveButton then
        local show = possible and true or false
        if caveButton:IsShown() ~= show then caveButton:SetShown(show) end
        caveButton:SetText(cave.active and "Normal map" or "Cave view")
    end
end

ns:RegisterOption({
    key = "mapCaveView",
    type = "toggle",
    label = "Cave view: show the minimap's cave picture on the world map",
    tooltip = "In caves (and buildings) the world map only shows the outdoor zone, but the minimap draws the inside. With this on, opening the map indoors shows the minimap there instead - big and zoomed out; mouse wheel zooms it. It shows what the minimap draws around you (no panning: the minimap is always centred on you). The Cave view / Normal map button at the bottom-left switches between the two. Your minimap goes back to its corner when you close the map.",
    default = true,
    onChange = function(v) if not v then CaveStop() end end,
})

-- TEMPORARY: where does a map sit in the world? /p13 mapinfo <part of a name>, then /reload;
-- the results land in SavedVariables (P13TweaksDB.mapInfoLog) for reading outside the game.
ns:RegisterCommand("mapinfo", "record which world a map belongs to (temporary, for terrain)", function(text)
    local want = strtrim(text or ""):lower()
    if want == "" then want = "zephras" end
    local log = { "searching for: " .. want }
    P13TweaksDB.mapInfoLog = log   -- saved as we go, so an error part-way still leaves something
    local okY, y, x, _, instance = pcall(UnitPosition, "player")
    table.insert(log, ("you: world %s,%s instance %s, best map %s"):format(tostring(y), tostring(x),
        tostring(instance), tostring(C_Map.GetBestMapForUnit("player"))))
    for id = 1, 3000 do
        local ok, err = pcall(function()
            local info = C_Map.GetMapInfo(id)
            if not (info and info.name and info.name:lower():find(want, 1, true)) then return end
            local c1, tl = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(0, 0))
            local c2, br = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(1, 1))
            local a, b, c, d
            if tl then a, b = tl:GetXY() end
            if br then c, d = br:GetXY() end
            local parent = info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
            table.insert(log, ("map %d %q type %s parent %s (%s) | world %s: %s,%s to %s: %s,%s"):format(id, info.name,
                tostring(info.mapType), tostring(info.parentMapID), parent and parent.name or "?",
                tostring(c1), tostring(a), tostring(b), tostring(c2), tostring(c), tostring(d)))
        end)
        if not ok then table.insert(log, ("map %d: error %s"):format(id, tostring(err))) end
    end
    table.insert(log, "done")
    for _, line in ipairs(log) do ns:Print(line) end
end)

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.Child and sc.GetCanvasScale and sc.GetNormalizedHorizontalScroll) then return end

    -- One flat sea colour behind everything: where the terrain tiles don't reach (sea, and the
    -- margin past the map's edge) you get this, not the map window's wooden frame or painted
    -- ocean. A texture of the scroll area itself, so it always draws beneath the map's contents.
    blackFill = sc:CreateTexture(nil, "BACKGROUND")
    blackFill:SetAllPoints(sc)
    ns.ApplySeaColour()
    blackFill:Hide()

    layer = CreateFrame("Frame", nil, sc.Child)
    layer:SetAllPoints(sc.Child)
    layer:SetFrameLevel(sc.Child:GetFrameLevel())  -- under the pins

    -- Opaque sea inside the tile layer, beneath the tiles: far larger than the map so it fills the whole
    -- pane at any zoom or pan (a texture isn't clipped by its frame; the scroll area clips it to the pane).
    seaTop = layer:CreateTexture(nil, "BACKGROUND", nil, -8)
    seaTop:SetPoint("TOPLEFT", sc.Child, "TOPLEFT", -6000, 6000)
    seaTop:SetPoint("BOTTOMRIGHT", sc.Child, "BOTTOMRIGHT", 6000, -6000)
    seaTop:Hide()
    ns.ApplySeaColour()

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

    -- Cave view: a dark backing over the map picture (the square minimap sits on it), which
    -- also takes the mouse wheel so it zooms the minimap instead of the hidden map.
    caveBack = CreateFrame("Frame", nil, sc)
    caveBack:SetAllPoints(sc)
    caveBack:SetFrameLevel(sc:GetFrameLevel() + 60)
    local bg = caveBack:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.03, 0.03, 1)
    caveBack:EnableMouse(true)
    caveBack:EnableMouseWheel(true)
    caveBack:SetScript("OnMouseWheel", CaveWheel)
    caveBack:Hide()

    caveBack:SetScript("OnSizeChanged", CaveLayout)

    -- invisible layer over the minimap that takes the mouse wheel (zooms the minimap)
    caveCatch = CreateFrame("Frame", nil, caveBack)
    caveCatch:SetAllPoints(caveBack)
    caveCatch:EnableMouseWheel(true)
    caveCatch:SetScript("OnMouseWheel", CaveWheel)

    -- our player arrow for the borrowed minimap: points the way you face, or straight up
    -- when your minimap is set to rotate (then the minimap turns instead)
    caveArrow = CreateFrame("Frame", nil, caveBack)
    caveArrow:SetSize(28, 28)
    local at = caveArrow:CreateTexture(nil, "OVERLAY")
    at:SetAllPoints()
    at:SetTexture("Interface\\AddOns\\P13Tweaks\\Media\\Arrow.tga")
    at:SetVertexColor(1, 0.85, 0.2)
    caveArrow:SetScript("OnUpdate", function()
        local facing = GetPlayerFacing and GetPlayerFacing()
        local rotating = GetCVarBool and GetCVarBool("rotateMinimap")
        if rotating or not facing or (issecretvalue and issecretvalue(facing)) then
            at:SetRotation(0)
        else
            at:SetRotation(facing)   -- 0 = north (up), turning left = anticlockwise
        end
    end)
    caveArrow:Hide()

    caveButton = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    caveButton:SetSize(100, 22)
    caveButton:SetFrameLevel(sc:GetFrameLevel() + 100)
    caveButton:SetScript("OnClick", function()
        cave.userOff = cave.active   -- on -> off for this visit indoors, off -> on
        CaveCheck()
    end)
    caveButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText(cave.active and "Back to the normal map" or "Cave view")
        GameTooltip:AddLine("The world map has no picture of this cave or building; the minimap does. Cave view shows the minimap here, big. Mouse wheel zooms it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    caveButton:SetScript("OnLeave", GameTooltip_Hide)
    caveButton:Hide()
    ns:AddMapButton(caveButton, 15)
    WorldMapFrame:HookScript("OnHide", CaveStop)

    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    local sinceCave = 1
    poll:SetScript("OnUpdate", function(_, elapsed)
        Refresh(false)
        -- Debug aid: with mapDebug on, holding Shift records the terrain tile under the cursor
        -- (column, row, file ID, map) in P13TweaksDB.mapDebugTiles, to find tiles that draw wrong.
        if P13TweaksDB and P13TweaksDB.mapDebug and IsShiftKeyDown() then
            local cx, cy = GetCursorPosition()
            for key, t in pairs(tilesInUse) do
                local l, r, top, bot = t:GetLeft(), t:GetRight(), t:GetTop(), t:GetBottom()
                local s = t:GetEffectiveScale()
                if l and r and top and bot and cx / s >= l and cx / s <= r and cy / s >= bot and cy / s <= top then
                    local cont = math.floor(key / 4096)
                    local idx = key % 4096
                    local rec = ("world %d col %d row %d id %s"):format(cont, math.floor(idx / 64), idx % 64,
                        tostring(ns.TerrainTiles[cont] and ns.TerrainTiles[cont][idx]))
                    P13TweaksDB.mapDebugTiles = P13TweaksDB.mapDebugTiles or {}
                    local seen = false
                    for _, x in ipairs(P13TweaksDB.mapDebugTiles) do if x == rec then seen = true break end end
                    if not seen then table.insert(P13TweaksDB.mapDebugTiles, rec) end
                end
            end
        end
        sinceCave = sinceCave + elapsed
        if sinceCave >= 0.25 then sinceCave = 0; CaveCheck() end
    end)
    poll:SetScript("OnShow", function() sinceCave = 1; Refresh(true) end)
end)

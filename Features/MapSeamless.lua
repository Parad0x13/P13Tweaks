-- P13Tweaks feature: one seamless world map.
-- Zooming in on a continent hands over to the zone under the middle of the view at the exact
-- same scale and spot; zooming out of a fully zoomed-out zone hands over to its continent the
-- same way (and continent <-> world). To the eye, it's one map you zoom through.
--
-- Scrolling out always pulls back around the mouse cursor (the spot under it stays put).
local ADDON_NAME, ns = ...

local SWITCH_COOLDOWN = 0.35  -- seconds between map hand-overs
local WHEEL_MEMORY    = 0.6   -- a hand-over in only happens this soon after you scrolled in
local STEP_FACTOR     = 1.5   -- zoom step size for the extra continent zoom levels

local lastSwitch, lastWheelIn = 0, 0

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

local function Art(mapID)
    local layers = mapID and C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(mapID)
    local l = layers and layers[1]
    if l and l.layerWidth and l.layerHeight then return l.layerWidth, l.layerHeight end
end

-- Where `child` sits on `parent`, in the parent's 0-1 coordinates: minX, minY, width, height.
local function Rect(child, parent)
    if not (C_Map.GetMapRectOnMap and child and parent) then return end
    local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(child, parent)
    if minX and maxX and maxX > minX and maxY > minY then
        return minX, minY, maxX - minX, maxY - minY
    end
end

-- Parent-map scale at which `child` just fits on screen.
local function FitScale(child, parent)
    local sc = WorldMapFrame.ScrollContainer
    local _, _, rw, rh = Rect(child, parent)
    local pw, ph = Art(parent)
    if not (rw and pw) then return end
    return math.min(sc:GetWidth() / (rw * pw), sc:GetHeight() / (rh * ph))
end

-- Same visible area, expressed as a scale on the other map.
local function ChildScaleFromParent(parentScale, child, parent)
    local _, _, rw = Rect(child, parent)
    return parentScale * rw * Art(parent) / Art(child)
end
local function ParentScaleFromChild(childScale, child, parent)
    local _, _, rw = Rect(child, parent)
    return childScale * Art(child) / (rw * Art(parent))
end

local function ViewCentre(sc)
    return sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
end

-- Switch maps without the "map changed" ring and with our own zoom applied straight away.
local function SwitchTo(mapID, scale, x, y)
    local sc = WorldMapFrame.ScrollContainer
    ns.suppressMapRing = true
    WorldMapFrame:SetMapID(mapID)
    ns.suppressMapRing = false
    sc:InstantPanAndZoom(scale, x, y, true)
    lastSwitch = GetTime()
end

---------------------------------------------------------------------------
-- Let continents zoom in far enough for any of their zones to fill the screen
---------------------------------------------------------------------------

local function ExtendZoomLevels(sc)
    if not ns:Get("mapSeamless") then return end
    local mapID = sc.mapID or WorldMapFrame:GetMapID()
    local levels = sc.zoomLevels
    local last = levels and levels[#levels]
    if not (mapID and last and last.scale and C_Map.GetMapChildrenInfo) then return end

    local need = 0
    for _, child in ipairs(C_Map.GetMapChildrenInfo(mapID) or {}) do
        local fit = FitScale(child.mapID, mapID)
        if fit and fit > need then need = fit end
    end
    local scale = last.scale
    while scale < need do
        scale = math.min(scale * STEP_FACTOR, need)
        table.insert(levels, { scale = scale, layerIndex = last.layerIndex })
    end
end

---------------------------------------------------------------------------
-- Finer zoom: split each of the game's zoom steps into smaller ones
---------------------------------------------------------------------------

-- How much one scroll zooms, as a factor (1.25 = 25%), or nil for the game's own steps.
local function ZoomStepFactor()
    local pct = tonumber(ns:Get("mapZoomStep"))
    if pct and pct >= 5 and pct <= 200 then return 1 + pct / 100 end
end

local function RefineZoomLevels(sc)
    local factor = ZoomStepFactor()
    local levels = sc.zoomLevels
    if not (factor and levels and #levels >= 2) then return end
    local out = {}
    for i = 1, #levels - 1 do
        local a, b = levels[i], levels[i + 1]
        table.insert(out, a)
        if a.scale and b.scale and b.scale > a.scale then
            local n = math.ceil(math.log(b.scale / a.scale) / math.log(factor) - 0.01)
            local ratio = (b.scale / a.scale) ^ (1 / n)
            for k = 1, n - 1 do
                -- in-between steps keep the lower step's art detail until the next real step
                table.insert(out, { scale = a.scale * ratio ^ k, layerIndex = a.layerIndex })
            end
        end
    end
    table.insert(out, levels[#levels])
    wipe(levels)                         -- refill in place: the map keeps a reference to this table
    for i, level in ipairs(out) do levels[i] = level end
end

-- Extra zoom past the game's closest step: one more step, `pct`% closer (100 = twice as close).
local function AddExtraZoomIn(sc)
    local pct = tonumber(ns:Get("mapExtraZoomIn"))
    local levels = sc.zoomLevels
    local last = levels and levels[#levels]
    if not (pct and pct > 0 and last and last.scale) then return end
    pct = math.min(pct, 1000)
    table.insert(levels, { scale = last.scale * (1 + pct / 100), layerIndex = last.layerIndex })
end

local function AdjustZoomLevels(sc)
    ExtendZoomLevels(sc)
    AddExtraZoomIn(sc)
    RefineZoomLevels(sc)   -- last, so the extra zoom range gets the same fine steps
end

---------------------------------------------------------------------------
-- Zooming in: continent -> zone
---------------------------------------------------------------------------

-- The direct child of `mapID` under point (x, y), if any.
local function ChildAt(mapID, x, y)
    if not (mapID and x and y) then return end
    local info = C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(mapID, x, y)
    while info and info.parentMapID and info.parentMapID ~= mapID do
        if info.parentMapID == 0 then info = nil; break end
        info = C_Map.GetMapInfo(info.parentMapID)
    end
    if info and info.mapID ~= mapID then return info.mapID end

    -- Fallback (e.g. continents on the world map): the smallest child whose area holds the point.
    local best, bestArea
    for _, child in ipairs((C_Map.GetMapChildrenInfo and C_Map.GetMapChildrenInfo(mapID)) or {}) do
        local minX, minY, rw, rh = Rect(child.mapID, mapID)
        if minX and x >= minX and x <= minX + rw and y >= minY and y <= minY + rh then
            if not bestArea or rw * rh < bestArea then best, bestArea = child.mapID, rw * rh end
        end
    end
    return best
end

local function CursorPos(sc)
    if sc.GetNormalizedCursorPosition and sc:IsMouseOver() then return sc:GetNormalizedCursorPosition() end
end

-- Zoom from `fromScale` to `toScale` keeping map point (ax, ay) under the same spot on screen.
local function ZoomAround(sc, ax, ay, fromScale, toScale)
    if not (sc.SetZoomTarget and toScale) then return end
    sc:SetZoomTarget(toScale)
    if not (ax and sc.SetPanTarget) then return end
    local cx, cy = ViewCentre(sc)
    local k = fromScale / toScale
    sc:SetPanTarget(ax + (cx - ax) * k, ay + (cy - ay) * k)
end

-- What you're zooming into: the map under the mouse if there is one, else under the view's middle.
local function TargetChild(sc, mapID)
    local child = ChildAt(mapID, CursorPos(sc))
    if child then return child end
    return ChildAt(mapID, ViewCentre(sc))
end

-- Hand over to `child`, matching scale and position when we know the geometry.
local function EnterChild(sc, mapID, child)
    local minX, minY, rw, rh = Rect(child, mapID)
    if minX and Art(child) and Art(mapID) then
        local cx, cy = ViewCentre(sc)
        local x = math.min(math.max((cx - minX) / rw, 0), 1)
        local y = math.min(math.max((cy - minY) / rh, 0), 1)
        SwitchTo(child, ChildScaleFromParent(sc:GetCanvasScale(), child, mapID), x, y)
    else
        ns.suppressMapRing = true
        WorldMapFrame:SetMapID(child)   -- no geometry: same as clicking it
        ns.suppressMapRing = false
        lastSwitch = GetTime()
    end
end

local function CheckZoomIn()
    if not ns:Get("mapSeamless") or not WorldMapFrame:IsShown() then return end
    local now = GetTime()
    if now - lastWheelIn > WHEEL_MEMORY or now - lastSwitch < SWITCH_COOLDOWN then return end

    local sc = WorldMapFrame.ScrollContainer
    local mapID = WorldMapFrame:GetMapID()
    local child = mapID and TargetChild(sc, mapID)
    local fit = child and FitScale(child, mapID)
    if not fit or sc:GetCanvasScale() < fit * 0.98 then return end
    EnterChild(sc, mapID, child)
end

local function IsFullyZoomedIn(sc)
    if sc.GetScaleForMaxZoom then return sc:GetCanvasScale() >= sc:GetScaleForMaxZoom() - 0.001 end
    if sc.IsZoomedIn then return sc:IsZoomedIn() end
end

---------------------------------------------------------------------------
-- Zooming out: zone -> continent
---------------------------------------------------------------------------

local function IsFullyZoomedOut(sc)
    if sc.GetScaleForMinZoom then return sc:GetCanvasScale() <= sc:GetScaleForMinZoom() + 0.001 end
    if sc.IsZoomedOut then return sc:IsZoomedOut() end
end

local function NextLowerScale(sc, scale)
    local best
    for _, level in ipairs(sc.zoomLevels or {}) do
        if level.scale < scale * 0.99 and (not best or level.scale > best) then best = level.scale end
    end
    return best
end

local function ZoomOutToParent(sc)
    local mapID = WorldMapFrame:GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    local parent = info and info.parentMapID
    if not parent or parent == 0 then return end

    local minX, minY, rw, rh = Rect(mapID, parent)
    if not minX then  -- no geometry for this pair: plain switch
        WorldMapFrame:SetMapID(parent)
        lastSwitch = GetTime()
        return
    end

    -- Show exactly the same area on the parent map...
    local cx, cy = ViewCentre(sc)
    local ux, uy = CursorPos(sc)
    SwitchTo(parent, ParentScaleFromChild(sc:GetCanvasScale(), mapID, parent), minX + cx * rw, minY + cy * rh)

    -- ...then keep pulling back one step around the cursor, like any other scroll out.
    local scale = sc:GetCanvasScale()
    local ax, ay
    if ux then ax, ay = minX + ux * rw, minY + uy * rh end
    ZoomAround(sc, ax, ay, scale, NextLowerScale(sc, scale))
end

---------------------------------------------------------------------------
-- Mouse wheel
---------------------------------------------------------------------------

-- Where the zoom was heading as of the last frame, i.e. before this wheel turn changed it.
local prevTargetScale
local function WasAtMaxZoom(sc)
    if not (sc.GetScaleForMaxZoom and prevTargetScale) then return IsFullyZoomedIn(sc) end
    return prevTargetScale >= sc:GetScaleForMaxZoom() - 0.001
end

local function OnWheel(sc, delta)
    if delta > 0 then
        lastWheelIn = GetTime()
        if not WasAtMaxZoom(sc) then return end
        -- Can't zoom this map any further (e.g. the world map)? Scrolling in over a
        -- continent or zone goes straight into it.
        if ns:Get("mapSeamless") and GetTime() - lastSwitch >= SWITCH_COOLDOWN then
            local mapID = WorldMapFrame:GetMapID()
            local child = mapID and TargetChild(sc, mapID)
            if child then EnterChild(sc, mapID, child); return end
        end
        -- Nothing to zoom into: the game would still slide the map toward the cursor. Stay put.
        if sc.SetPanTarget then sc:SetPanTarget(ViewCentre(sc)) end
        return
    end

    -- Checked before the zoom animation moves, so this is the state when you scrolled.
    if IsFullyZoomedOut(sc) then
        if ns:Get("mapSeamless") and GetTime() - lastSwitch >= SWITCH_COOLDOWN then
            ZoomOutToParent(sc)
        end
        return
    end

    -- Normal scroll out: pull back around the cursor. The game already set the new zoom
    -- target; we only set where the view should end up.
    local from = prevTargetScale or sc:GetCanvasScale()
    local to = NextLowerScale(sc, from)
    local ux, uy = CursorPos(sc)
    if to and ux and sc.SetPanTarget then
        local cx, cy = ViewCentre(sc)
        local k = sc:GetCanvasScale() / to
        sc:SetPanTarget(ux + (cx - ux) * k, uy + (cy - uy) * k)
    end
end

ns:RegisterOption({
    key = "mapSeamless",
    type = "toggle",
    label = "Seamless map zoom (world, continent, zone)",
    tooltip = "Zoom straight through map levels as if they were one map: zooming in on a continent hands over to the zone in the middle of the view, and zooming out of a zone hands over to its continent, at the same scale and spot.",
    default = true,
    onChange = function()
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        if sc and sc.CreateZoomLevels and WorldMapFrame:GetMapID() then sc:CreateZoomLevels() end
    end,
})

ns:RegisterOption({
    key = "mapZoomStep",
    type = "text",
    label = "Map zoom per scroll (%), blank = game default",
    tooltip = "How much each mouse-wheel scroll zooms the map. Smaller = finer control, e.g. 15. Any number from 5 to 200; leave blank for the game's own big steps. Press Enter to save.",
    default = "20",
    maxLetters = 3,
    onChange = function()
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        if sc and sc.CreateZoomLevels and WorldMapFrame:GetMapID() then sc:CreateZoomLevels() end
    end,
})

ns:RegisterOption({
    key = "mapExtraZoomIn",
    type = "text",
    label = "Extra map zoom-in (%), 0 = none",
    tooltip = "Lets you zoom in past the game's closest zoom. 100 = twice as close as normal, 200 = three times. Any number from 0 to 1000. Press Enter to save.",
    default = "0",
    maxLetters = 4,
    onChange = function()
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        if sc and sc.CreateZoomLevels and WorldMapFrame:GetMapID() then sc:CreateZoomLevels() end
    end,
})

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", function()
    -- tidy up settings from the older jump-up-a-map options this replaces
    P13TweaksDB.mapZoomOutParent, P13TweaksDB.mapParentCentre, P13TweaksDB.mapZoomOutCentre = nil, nil, nil

    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.InstantPanAndZoom and sc.GetNormalizedHorizontalScroll) then return end
    sc:HookScript("OnMouseWheel", OnWheel)
    if sc.CreateZoomLevels then hooksecurefunc(sc, "CreateZoomLevels", AdjustZoomLevels) end

    -- Watch the zoom while the map is open, to hand over to a zone once it fills the view.
    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function()
        prevTargetScale = sc.targetScale or sc:GetCanvasScale()
        CheckZoomIn()
    end)
end)

-- P13Tweaks: "centre the world map on me", used by middle-click on the map (MapMiddleClick.lua).
-- (The old F-key binding for this has been removed.)
local ADDON_NAME, ns = ...

local CLOSE_VIEW_YARDS = 800   -- "zoom in on me": about this many yards across the map view

-- Map zoom at which the view is about `yards` wide on `mapID`, kept within the map's own limits.
local function ScaleForYards(sc, mapID, yards, noClamp)
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
    local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
    local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
    local W = sc.Child and sc.Child:GetWidth()
    if not (a and b and W and W > 0) then return end
    local _, left = a:GetXY()
    local _, right = b:GetXY()
    local mapYards = math.abs(left - right)
    if mapYards <= 0 then return end
    local scale = sc:GetWidth() * mapYards / (W * yards)
    if noClamp then return scale end   -- (the caller holds it to the limits of the map it ends up on)
    if sc.GetScaleForMinZoom then scale = math.max(scale, sc:GetScaleForMinZoom()) end
    if sc.GetScaleForMaxZoom then scale = math.min(scale, sc:GetScaleForMaxZoom()) end
    return scale
end

-- The zoom, on map `cur`, at which the view shows the same area as the close-up on the player's own map
-- (`playerMap`, usually a zone). Flying to the close-up of `cur` itself (a continent...) would zoom far past
-- it before the hand-over to the zone, and the zone then zoomed back OUT to its close-up.
local function CloseScaleOn(sc, cur, playerMap)
    if cur == playerMap or not (ns.MapPoint and C_Map.GetMapArtLayers) then
        return ScaleForYards(sc, cur, CLOSE_VIEW_YARDS, true)
    end
    local s = ScaleForYards(sc, playerMap, CLOSE_VIEW_YARDS, true)
    local u0 = ns.MapPoint(playerMap, cur, 0, 0)
    local u1 = ns.MapPoint(playerMap, cur, 1, 0)
    local a, b = C_Map.GetMapArtLayers(playerMap), C_Map.GetMapArtLayers(cur)
    local aw = a and a[1] and a[1].layerWidth
    local bw = b and b[1] and b[1].layerWidth
    if s and u0 and u1 and u1 > u0 and aw and bw then
        local scale = s * aw / ((u1 - u0) * bw)
        return scale
    end
    return ScaleForYards(sc, cur, CLOSE_VIEW_YARDS, true)
end

-- With the tile-map zoom on: fly to the player on the map being shown (zooming out first if it's far),
-- whatever map level they're on. Returns false if that isn't possible and the old way should be used.
-- Where `unit` is: its best map and its x, y on it, or nil (not on a map, another instance, secret values).
local function UnitMapPos(unit)
    local m = C_Map.GetBestMapForUnit(unit)
    if not m or (issecretvalue and issecretvalue(m)) then return end
    local pos = C_Map.GetPlayerMapPosition(m, unit)
    if not pos then return end
    local px, py = pos:GetXY()
    if px == nil or (issecretvalue and (issecretvalue(px) or issecretvalue(py))) then return end
    if px == 0 and py == 0 then return end
    return m, px, py
end
ns.UnitMapPos = UnitMapPos

local function FlyToPlayer(zoomIn, unit)
    if not (ns.FlyTo and ns.MapPoint and ns.sheetZoomActive and ns.sheetZoomActive()) then return false end
    local sc = WorldMapFrame.ScrollContainer
    local playerMap, px, py = UnitMapPos(unit)
    if not playerMap then return false end
    local cur = WorldMapFrame:GetMapID()
    local u, v = ns.MapPoint(playerMap, cur, px, py)
    if not u then return false end   -- an unrelated map: the old way switches to the player's map
    return ns.FlyTo(u, v, zoomIn and CloseScaleOn(sc, cur, playerMap) or nil, zoomIn)
end

-- The close-up zoom for a map (used when a fly-to hands over to another map on the way in).
ns.CloseViewScale = function(mapID)
    return ScaleForYards(WorldMapFrame.ScrollContainer, mapID, CLOSE_VIEW_YARDS, true)
end

-- zoomIn: also zoom in close around you (middle-click); otherwise keep the zoom.
-- unit: who to centre on (default "player"; the party-cycle button passes "party1" etc.).
-- Returns true if it found them on a map.
local function CentreOnPlayer(zoomIn, unit)
    unit = unit or "player"
    if not WorldMapFrame:IsShown() then return end
    local sc = WorldMapFrame.ScrollContainer
    if not UnitMapPos(unit) then return false end   -- not on any map we can show (e.g. in another instance)
    if ns.CancelSheetZoom then ns.CancelSheetZoom() end   -- the tile-map zoom must not pull the view back
    if FlyToPlayer(zoomIn, unit) then return true end

    -- Looking at a different map (another zone, the continent, the world)? Go to their zone first.
    local playerMap = UnitMapPos(unit)
    if playerMap and playerMap ~= WorldMapFrame:GetMapID() then
        ns.suppressMapRing = true    -- switching maps would normally replay the ring
        WorldMapFrame:SetMapID(playerMap)
        ns.suppressMapRing = false
    end

    local pos = C_Map.GetPlayerMapPosition(WorldMapFrame:GetMapID(), unit)
    local px, py
    if pos then px, py = pos:GetXY() end
    if not px or (issecretvalue and (issecretvalue(px) or issecretvalue(py))) or (px == 0 and py == 0) then
        return false
    end

    local scale = zoomIn and ScaleForYards(sc, WorldMapFrame:GetMapID(), CLOSE_VIEW_YARDS)
    if scale then
        if ns:Get("mapSmoothPan") and sc.SetPanTarget and sc.SetZoomTarget then
            sc:SetPanTarget(px, py)      -- glide over and in
            sc:SetZoomTarget(scale)
        else
            sc:InstantPanAndZoom(scale, px, py, true)
        end
    elseif ns:Get("mapSmoothPan") and sc.SetPanTarget then
        sc:SetPanTarget(px, py)          -- glide over
    else
        sc:InstantPanAndZoom(sc:GetCanvasScale(), px, py, true)
    end
    return true
end

ns.CentreMapOnPlayer = CentreOnPlayer

ns:RegisterOption({
    key = "mapSmoothPan",
    type = "toggle",
    label = "Smoothly pan when centring",
    tooltip = "When you middle-click the map to centre on yourself, the map glides over to you instead of jumping.",
    default = true,
})

-- (The Center button on the map was removed: middle-click does the same.)

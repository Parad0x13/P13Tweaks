-- P13Tweaks: "centre the world map on me", used by middle-click on the map (MapMiddleClick.lua).
-- (The old F-key binding for this has been removed.)
local ADDON_NAME, ns = ...

local CLOSE_VIEW_YARDS = 800   -- "zoom in on me": about this many yards across the map view

-- Map zoom at which the view is about `yards` wide on `mapID`, kept within the map's own limits.
local function ScaleForYards(sc, mapID, yards)
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
    if sc.GetScaleForMinZoom then scale = math.max(scale, sc:GetScaleForMinZoom()) end
    if sc.GetScaleForMaxZoom then scale = math.min(scale, sc:GetScaleForMaxZoom()) end
    return scale
end

-- With the tile-map zoom on: fly to the player on the map being shown (zooming out first if it's far),
-- whatever map level they're on. Returns false if that isn't possible and the old way should be used.
local function FlyToPlayer(zoomIn)
    if not (ns.FlyTo and ns.MapPoint and ns.sheetZoomActive and ns.sheetZoomActive()) then return false end
    local sc = WorldMapFrame.ScrollContainer
    local playerMap = C_Map.GetBestMapForUnit("player")
    if not playerMap then return false end
    local pos = C_Map.GetPlayerMapPosition(playerMap, "player")
    local px, py
    if pos then px, py = pos:GetXY() end
    if not px or (px == 0 and py == 0) then return false end
    local cur = WorldMapFrame:GetMapID()
    local u, v = ns.MapPoint(playerMap, cur, px, py)
    if not u then return false end   -- an unrelated map: the old way switches to the player's map
    return ns.FlyTo(u, v, zoomIn and ScaleForYards(sc, cur, CLOSE_VIEW_YARDS) or nil)
end

-- zoomIn: also zoom in close around you (middle-click); otherwise keep the zoom.
local function CentreOnPlayer(zoomIn)
    if not WorldMapFrame:IsShown() then return end
    local sc = WorldMapFrame.ScrollContainer
    if ns.CancelSheetZoom then ns.CancelSheetZoom() end   -- the tile-map zoom must not pull the view back
    if FlyToPlayer(zoomIn) then return end

    -- Looking at a different map (another zone, the continent, the world)? Go to your zone first.
    local playerMap = C_Map.GetBestMapForUnit("player")
    if playerMap and playerMap ~= WorldMapFrame:GetMapID() then
        ns.suppressMapRing = true    -- switching maps would normally replay the ring
        WorldMapFrame:SetMapID(playerMap)
        ns.suppressMapRing = false
    end

    local pos = C_Map.GetPlayerMapPosition(WorldMapFrame:GetMapID(), "player")
    local px, py
    if pos then px, py = pos:GetXY() end
    if not px or (px == 0 and py == 0) then return end

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

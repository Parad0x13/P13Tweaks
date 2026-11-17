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

-- zoomIn: also zoom in close around you (the map's Center button); otherwise keep the zoom.
local function CentreOnPlayer(zoomIn)
    if not WorldMapFrame:IsShown() then return end
    local sc = WorldMapFrame.ScrollContainer

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

ns:RegisterOption({
    key = "mapCenterButton",
    type = "toggle",
    label = "Center button on the world map",
    tooltip = "A Center button in the bottom-left corner of the world map: switches to your zone, centres on you and zooms in close.",
    default = true,
    onChange = function(v)
        if ns.mapCenterButton then ns.mapCenterButton:SetShown(v and true or false) end
    end,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    P13TweaksDB.mapCenterKey = nil   -- removed option (F to centre)

    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc then return end
    -- second in the bottom-left button row (Core.lua), after the terrain/painted button
    local button = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    button:SetSize(70, 22)
    button:SetText("Center")
    button:SetFrameLevel(sc:GetFrameLevel() + 100)
    button:SetScript("OnClick", function() CentreOnPlayer(true) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("Center on me")
        GameTooltip:AddLine("Switches to your zone, centres on you and zooms in close.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetShown(ns:Get("mapCenterButton") and true or false)
    ns.mapCenterButton = button
    ns:AddMapButton(button, 20)
end)

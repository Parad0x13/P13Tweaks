-- P13Tweaks: "centre the world map on me", used by middle-click on the map (MapMiddleClick.lua).
-- (The old F-key binding for this has been removed.)
local ADDON_NAME, ns = ...

local function CentreOnPlayer()
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

    if ns:Get("mapSmoothPan") and sc.SetPanTarget then
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

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    P13TweaksDB.mapCenterKey = nil   -- removed option (F to centre)
end)

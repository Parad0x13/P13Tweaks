-- P13Tweaks feature: the world map reopens on the same map, zoom and pan you left it at.
local ADDON_NAME, ns = ...

local function Scroll() return WorldMapFrame.ScrollContainer end

local function Save()
    local sc = Scroll()
    if not ns:Get("mapRemember") or not sc then return end
    P13TweaksDB.mapState = {
        mapID = WorldMapFrame:GetMapID(),
        scale = sc:GetCanvasScale(),
        x = sc:GetNormalizedHorizontalScroll(),
        y = sc:GetNormalizedVerticalScroll(),
        playerMap = C_Map.GetBestMapForUnit("player"),
    }
end

local function Restore()
    local s, sc = P13TweaksDB.mapState, Scroll()
    if not ns:Get("mapRemember") or not s or not s.mapID or not sc then return end
    if not WorldMapFrame:IsShown() or not s.scale then return end

    -- In a cave or dungeon that has its own map: leave the game's cave map alone (our saved
    -- zoom belongs to an outdoor map and would make no sense on it).
    local here = C_Map.GetBestMapForUnit("player")
    local info = here and C_Map.GetMapInfo(here)
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    if info and info.mapType and info.mapType > zoneType then
        if WorldMapFrame:GetMapID() ~= here then WorldMapFrame:SetMapID(here) end
        return
    end

    -- Same zone as when closed: reopen the map you were looking at.
    -- Changed zones: keep the map Blizzard picked (your new zone), but still keep the zoom.
    if s.playerMap == C_Map.GetBestMapForUnit("player") and WorldMapFrame:GetMapID() ~= s.mapID then
        WorldMapFrame:SetMapID(s.mapID)  -- note: changing map resets zoom, so zoom after
    end

    -- Your saved pan if this is the map you left, otherwise the middle of the map.
    local x, y = 0.5, 0.5
    if WorldMapFrame:GetMapID() == s.mapID and s.x and s.y then
        x, y = s.x, s.y
    end
    sc:InstantPanAndZoom(s.scale, x, y, true)
end

ns:RegisterOption({
    key = "mapRemember",
    type = "toggle",
    label = "Remember map zoom and position",
    tooltip = "The world map reopens on the map, zoom and pan you left it at. If you've changed zones since, it opens on your new zone at the same zoom. In a cave or dungeon with its own map, it opens on that map instead.",
    default = true,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local sc = Scroll()
    if not (sc and sc.InstantPanAndZoom and sc.GetNormalizedHorizontalScroll) then return end
    WorldMapFrame:HookScript("OnHide", Save)
    -- Wait one frame so Blizzard finishes its own open/reset first, then apply ours.
    WorldMapFrame:HookScript("OnShow", function() C_Timer.After(0, Restore) end)
end)

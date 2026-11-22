-- P13Tweaks feature: the world map reopens on the same map, zoom and pan you left it at.
local ADDON_NAME, ns = ...

local function Scroll() return WorldMapFrame.ScrollContainer end

-- The window comes in two sizes (maximized / windowed) and each remembers its own view: the scale number only
-- means something at one pane size, and you will have left each one somewhere different.
local function Mode() return (WorldMapFrame.IsMaximized and WorldMapFrame:IsMaximized()) and "max" or "win" end

local function Save()
    local sc = Scroll()
    if not ns:Get("mapRemember") or not sc then return end
    local scale = sc:GetCanvasScale()
    -- What part of the map was on screen, as a fraction of the map (width, height): the scale number alone
    -- only means something at the window size it was taken at (maximized, the pane is far bigger).
    local W, H = sc.Child and sc.Child:GetWidth(), sc.Child and sc.Child:GetHeight()
    local vw, vh
    if scale and scale > 0 and scale < math.huge and W and W > 0 and H and H > 0 and sc:GetWidth() > 0 then
        vw, vh = sc:GetWidth() / (scale * W), sc:GetHeight() / (scale * H)
    end
    local state = {
        mapID = WorldMapFrame:GetMapID(),
        scale = scale,
        vw = vw, vh = vh,
        x = sc:GetNormalizedHorizontalScroll(),
        y = sc:GetNormalizedVerticalScroll(),
        playerMap = C_Map.GetBestMapForUnit("player"),
    }
    P13TweaksDB.mapStates = P13TweaksDB.mapStates or {}
    P13TweaksDB.mapStates[Mode()] = state   -- this size's own view
    P13TweaksDB.mapState = state            -- and the latest of either (used when this size has none yet)
end

-- The zoom that shows the saved area in the window as it is NOW: the whole area you had on screen fits,
-- at any window size. (Same window size as when saved: exactly the saved scale.)
local function ScaleToRestore(s, sc)
    local W, H = sc.Child and sc.Child:GetWidth(), sc.Child and sc.Child:GetHeight()
    local pw, ph = sc:GetWidth(), sc:GetHeight()
    if s.vw and s.vh and s.vw > 0 and s.vh > 0 and W and W > 0 and H and H > 0 and pw and pw > 0 and ph and ph > 0 then
        return math.min(pw / (s.vw * W), ph / (s.vh * H))
    end
    return s.scale   -- (saved by an older version)
end

local function Restore()
    local sc = Scroll()
    -- the view this window size was left at (exactly); if it has none yet, the latest one of the other size
    local s = P13TweaksDB.mapStates and P13TweaksDB.mapStates[Mode()]
    local exact = s ~= nil
    s = s or P13TweaksDB.mapState
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
    sc:InstantPanAndZoom(exact and s.scale or ScaleToRestore(s, sc), x, y, true)
    -- tell the tile-map zoom this was a placement, not a request to glide there
    if ns.AdoptMapView then ns.AdoptMapView() end
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
    -- Wait one frame so Blizzard finishes its own open/reset first, then apply ours. The map pane can still be
    -- changing size then (maximized / windowed is applied as the window opens): if its size is different a
    -- moment later, put the view back once more, so it is worked out for the final size.
    WorldMapFrame:HookScript("OnShow", function()
        C_Timer.After(0, function()
            local w = Scroll() and Scroll():GetWidth() or 0
            Restore()
            C_Timer.After(0.2, function()
                local sc = Scroll()
                if sc and WorldMapFrame:IsShown() and math.abs(sc:GetWidth() - w) > 1 then Restore() end
            end)
        end)
    end)
end)

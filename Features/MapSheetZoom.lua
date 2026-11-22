-- P13Tweaks feature: tile-map style zoom and pan on the REAL world map.
-- The tilesheet window (MapSheet.lua) feels right because nothing else touches the view. The game's
-- own map code does: every frame it clamps the view to narrow limits and pulls it toward the middle
-- of the map, which wrecks zooming out and makes panning impossible when zoomed out. So here WE own
-- the view:
--   * our state (zoom + centre) is the truth, and we write it to the map every frame, AFTER the
--     game's own per-frame update (a HookScript), so what we write is what gets drawn;
--   * the mouse wheel is replaced: smooth zoom that keeps the spot under the cursor fixed;
--   * while you drag, the view follows the cursor with no limits at all;
--   * anything else that asks the map to move (middle-click centring, the nav bar...) shows up as a
--     new pan or zoom target on the map; we glide to it ourselves instead of letting the game clamp it.
-- The game keeps everything else: markers, clicks, panels, buttons.
local ADDON_NAME, ns = ...

local PAN_SMOOTH = 12      -- how fast a glide (e.g. centring on yourself) eases
local EPS        = 0.0004  -- positions closer than this (map fractions) count as the same

local sc, origWheel
local ownX, ownY, ownS      -- where the map is (we write this every frame)
local goalX, goalY, goalS   -- where it's heading
local anchored, anchorU, anchorV, anchorSx, anchorSy   -- wheel zoom: keep this map point under this screen spot
local lastMapID
local downOnMap, dragOn, dragPx, dragPy, dragX, dragY   -- left button: went down on the map; cursor and view at that moment
local lastTrace = 0
local switchedAt = 0           -- when MapSeamless last switched the map level (the game's targets are stale just after)
local fly                 -- a "fly to" in progress: { phase, tu, tv, midS, finalS } (map coordinates)

local function Enabled() return ns:Get("mapSheetZoom") end
ns.sheetZoomActive = Enabled   -- MapSeamless steps aside while this is on

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Zoom factor per wheel notch: 40%.
local function ZoomStep() return 1.4 end

-- How fast the zoom eases toward its goal, per second.
local function ZoomRate() return 10.5 end
local function Trace(text) if ns.MapTrace then ns.MapTrace("SZ " .. text) end end

-- Cursor position in screen pixels from the middle of the map view (x right, y down).
local function CursorOffset()
    local px, py = GetCursorPosition()
    local es = sc:GetEffectiveScale()
    local l, t = sc:GetLeft(), sc:GetTop()
    if not (l and t) then return 0, 0 end
    return px / es - l - sc:GetWidth() / 2, (t - py / es) - sc:GetHeight() / 2
end

local function Limits()
    local lo = sc.GetScaleForMinZoom and sc:GetScaleForMinZoom() or 0.5
    local hi = sc.GetScaleForMaxZoom and sc:GetScaleForMaxZoom() or 10
    -- extra zoom-in past the game's closest step (option "mapExtraZoomIn", % : 100 = twice as close)
    local extra = Clamp(tonumber(ns:Get("mapExtraZoomIn")) or 0, 0, 1000)
    -- A zone or continent that has a map above it: zooming out must carry on past this map's own limit, so the
    -- scrolls after it stay in the goal and the hand-over to the parent (MapSeamless) happens as you go. With
    -- the old limit, the notches landing between "zoomed out as far as this map goes" and the hand-over were
    -- thrown away and the zoom stalled until you scrolled again.
    local room = 0.8
    if ns:Get("mapSeamless") and C_Map and C_Map.GetMapInfo then
        local info = C_Map.GetMapInfo(WorldMapFrame:GetMapID() or 0)
        if info and info.parentMapID and info.parentMapID ~= 0 and info.mapType and info.mapType >= 2 then room = 0.25 end
    end
    return lo * room, hi * (1 + extra / 100)
end

-- Set the game's pan target and remember what it ended up as (it clamps the target to the limits of the
-- current zoom, so it isn't always what we asked for): a target different from THAT is somebody's request.
local leftX, leftY
local ours = false                 -- true while WE are calling SetPanTarget
local pendX, pendY                 -- a pan somebody ELSE asked for (a call to SetPanTarget that wasn't ours)
local function PutPanTarget(x, y)
    if not sc.SetPanTarget then return end
    ours = true
    sc:SetPanTarget(x, y)
    ours = false
    leftX, leftY = sc.targetScrollX, sc.targetScrollY
end

-- Pan requests are noticed by watching the CALLS to SetPanTarget, not by comparing the game's target with the
-- view: the game clamps targets to its limits and re-clamps them as the zoom changes, so the target it holds
-- can differ from the view with nobody having asked for anything (after a fly-to ending zoomed in, that looked
-- like a request to pan to the clamped spot, and the view slid off).
local function HookPanTarget()
    if sc.SetPanTarget and not sc.p13PanHooked then
        sc.p13PanHooked = true
        hooksecurefunc(sc, "SetPanTarget", function(_, x, y)
            if not ours and x and y then pendX, pendY = x, y end
        end)
    end
end

-- Take whatever the map is showing right now as our state (first frame, or after the map changed).
local function Adopt()
    ownS = sc:GetCanvasScale()
    ownX, ownY = sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
    goalX, goalY, goalS = ownX, ownY, ownS
    anchored = false
    leftX, leftY, pendX, pendY = nil, nil, nil, nil
    lastMapID = WorldMapFrame:GetMapID()
end

---------------------------------------------------------------------------
-- Mouse wheel
---------------------------------------------------------------------------

local function OnWheel(self, delta)
    if not (self.Child and ownS) then return end
    local W, H = self.Child:GetWidth(), self.Child:GetHeight()
    if not (ownS > 0 and ownS < math.huge and W and W > 0 and H and H > 0) then return end

    fly = nil   -- scrolling takes over from a fly-to
    local sx, sy = CursorOffset()
    anchorU, anchorV = ownX + sx / (ownS * W), ownY + sy / (ownS * H)
    anchorSx, anchorSy = sx, sy
    anchored = true

    local lo, hi = Limits()
    local step = ZoomStep()
    goalS = Clamp(goalS * (delta > 0 and step or 1 / step), lo, hi)
    Trace(("WHEEL %s  scale %.4f -> goal %.4f  anchor %.3f,%.3f"):format(delta > 0 and "IN" or "OUT", ownS, goalS, anchorU, anchorV))
end

---------------------------------------------------------------------------
-- Every frame, after the game's own update
---------------------------------------------------------------------------

local function Frame(dt)
    if not WorldMapFrame:IsShown() then return end
    local W, H = sc.Child:GetWidth(), sc.Child:GetHeight()
    if not (W and W > 0 and H and H > 0) then return end
    local cs = sc:GetCanvasScale()
    if not (cs and cs > 0 and cs < math.huge) then return end

    -- first frame, or somebody changed the map: start from what it shows
    if not ownS or WorldMapFrame:GetMapID() ~= lastMapID then
        Adopt()
        Trace(("ADOPT map %s  scale %.4f view %.3f,%.3f"):format(tostring(lastMapID), ownS, ownX, ownY))
        return
    end

    -- Is the left button held since it went down on the map? Is that a drag yet? We decide that
    -- ourselves (the cursor moved a few pixels) instead of waiting for the game's own "panning" flag:
    -- the game only raises it when ITS pan target moves, and we keep resetting that target.
    local leftDown = downOnMap and IsMouseButtonDown("LeftButton")
    local released = false
    if downOnMap and not leftDown then downOnMap, released = false, true end
    local dragging = false
    if leftDown then
        local px, py = GetCursorPosition()
        dragging = dragOn or (sc.IsPanning and sc:IsPanning()) or math.abs(px - dragPx) > 3 or math.abs(py - dragPy) > 3
    end

    if dragging then
        -- 1. dragging: the view follows the cursor, with no limits
        if not dragOn then Trace("DRAG start") end
        fly = nil
        pendX, pendY = nil, nil
        dragOn = true
        local px, py = GetCursorPosition()
        local es = sc:GetEffectiveScale()
        ownX = dragX - (px - dragPx) / es / (ownS * W)
        ownY = dragY + (py - dragPy) / es / (ownS * H)
        goalX, goalY, goalS = ownX, ownY, ownS
        anchored = false
    else
        if dragOn then Trace(("DRAG end  view %.3f,%.3f"):format(ownX, ownY)) end
        dragOn = false

        if leftDown then
            -- button down, not dragging yet: hold the view where it is and leave the game's own
            -- bookkeeping (its targets) alone so it can notice the drag
            pendX, pendY = nil, nil
            goalX, goalY, goalS = ownX, ownY, ownS
            anchored = false
        else
            if released then
                -- the button just came up: whatever targets the game's drag left behind are not a request
                pendX, pendY = nil, nil
                PutPanTarget(ownX, ownY)
            elseif GetTime() - switchedAt <= 0.5 then
                pendX, pendY = nil, nil   -- (SetMapID resets the game's targets: not a request)
            else
                -- 2. somebody else asked the map to go somewhere (we leave its targets equal to our own
                --    state, so a target that differs from ours is a request): glide there ourselves.
                --    (Not just after a level switch: SetMapID resets the game's targets, which is not a request.)
                local ts = sc.targetScale
                if pendX and not anchored and (math.abs(pendX - ownX) > EPS or math.abs(pendY - ownY) > EPS) then
                    goalX, goalY = pendX, pendY
                    if not fly then Trace(("REQUEST pan -> %.3f,%.3f"):format(pendX, pendY)) end
                end
                pendX, pendY = nil, nil
                if ts and math.abs(ts - ownS) > ownS * 0.002 and not anchored and goalS == ownS then
                    goalS = ts
                    if not fly then Trace(("REQUEST zoom -> %.4f"):format(ts)) end
                end
            end

            -- a fly-to (middle-click centring): pan and zoom together in one glide
            if fly and not anchored then
                goalS, goalX, goalY = fly.finalS, fly.tu, fly.tv
                local dxp, dyp = (ownX - fly.tu) * W * ownS, (ownY - fly.tv) * H * ownS
                if dxp * dxp + dyp * dyp < 100 and math.abs(ownS - fly.finalS) < fly.finalS * 0.02 then
                    Trace(("FLY arrived  scale %.4f  goal %.4f"):format(ownS, fly.finalS))
                    goalS, fly = fly.finalS, nil
                end
                -- keep the game's own target equal to where we're heading, so it isn't taken for a request
                PutPanTarget(goalX, goalY)
            end

            -- 3. advance toward the goal
            if goalS ~= ownS then
                -- ease in log space, so every notch feels the same size zoomed in or out
                local rate = ZoomRate()
                ownS = ownS * (goalS / ownS) ^ (1 - math.exp(-rate * dt))
                if math.abs(goalS - ownS) < goalS * 0.0005 then ownS = goalS end
            end
            if anchored then   -- keep the map point you zoomed on exactly under the cursor
                ownX, ownY = anchorU - anchorSx / (ownS * W), anchorV - anchorSy / (ownS * H)
                goalX, goalY = ownX, ownY
                if ownS == goalS then anchored = false end
            elseif goalX ~= ownX or goalY ~= ownY then
                local k = 1 - math.exp(-PAN_SMOOTH * dt)
                ownX, ownY = ownX + (goalX - ownX) * k, ownY + (goalY - ownY) * k
                if math.abs(goalX - ownX) < 0.0002 and math.abs(goalY - ownY) < 0.0002 then ownX, ownY = goalX, goalY end
            end
        end
    end

    -- 4. write our state to the map (the game has just had its say this frame)
    local wrote = false   -- did we move the map this frame? (at rest, skip the redraw calls below)
    if math.abs(cs - ownS) > ownS * 0.0005 then
        wrote = true
        sc:InstantPanAndZoom(ownS, ownX, ownY, true)
        if ns.WidenMapLimits then ns.WidenMapLimits(sc) end
        if ns.SyncPlayerPin then ns.SyncPlayerPin() end   -- the arrow re-measures against the scale we just wrote
    end
    local gx, gy = sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
    if math.abs(gx - ownX) > EPS or math.abs(gy - ownY) > EPS then
        wrote = true
        if GetTime() - lastTrace > 0.5 and not dragging then
            lastTrace = GetTime()
            Trace(("GAME MOVED view %.3f,%.3f -> %.3f,%.3f  (put back)"):format(ownX, ownY, gx, gy))
        end
        if sc.SetNormalizedHorizontalScroll and sc.SetNormalizedVerticalScroll then
            sc:SetNormalizedHorizontalScroll(ownX)
            sc:SetNormalizedVerticalScroll(ownY)
        end
    end
    -- Redraw the overlays that scale themselves to the map (lines, terrain tiles) NOW, in the same
    -- frame: their own updates may have run before we moved the map, which showed one frame of them
    -- at the old zoom (a flicker). Both skip the work when nothing has changed.
    -- (only when the view is moving or was just moved: at rest each layer's own per-frame check is enough)
    if wrote or dragging or fly or anchored or goalS ~= ownS or goalX ~= ownX or goalY ~= ownY then
        if ns.RedrawMapDrawings then ns.RedrawMapDrawings() end
        if ns.RefreshMapTerrain then ns.RefreshMapTerrain(false) end
        ns.RefreshMapLayers()   -- icon layers (flight points...) at the scale we just wrote, not one frame late
    end

    -- the game's zoom target too: a stale one (left over from its own wheel handling) would otherwise
    -- look like a request to zoom there, and the view would glide back out to it
    -- (always: a request is looked at at the start of the NEXT frame, before this runs again, so
    -- syncing here can't swallow one; leaving it stale made finished zooms and fly-tos swing back)
    if sc.targetScale and sc.targetScale ~= ownS then
        sc.targetScale = ownS
    end

    -- leave the game's own targets equal to our state, so a request from someone else stands out
    -- (not while we're gliding to one, and never while the button is held)
    if not leftDown and sc.SetPanTarget and sc.targetScrollX
        and (math.abs(sc.targetScrollX - ownX) > EPS / 4 or math.abs(sc.targetScrollY - ownY) > EPS / 4)
        and not (goalX ~= ownX or goalY ~= ownY) then
        PutPanTarget(ownX, ownY)
    end
end

---------------------------------------------------------------------------
-- Things that talk to us
---------------------------------------------------------------------------

-- MapSeamless just switched the map level (zone <-> continent, or to a neighbouring zone). Carry our
-- state over so the zoom carries on smoothly: same goal (rescaled), same spot under the cursor.
ns.OnMapSwitch = function(oldMap, newMap, oldScale, newScale)
    if not (sc and Enabled() and ownS) then return end
    if fly then   -- the destination and the zooms are in the old map's terms: convert them
        local tu, tv
        if ns.MapPoint then tu, tv = ns.MapPoint(oldMap, newMap, fly.tu, fly.tv) end
        if tu and oldScale and oldScale > 0 and newScale and newScale > 0 then
            local k = newScale / oldScale
            fly.tu, fly.tv, fly.midS, fly.finalS = tu, tv, fly.midS * k, fly.finalS * k
            -- A close-up flight: the zoom worked out on the old map was held to ITS limits (a continent only
            -- zooms so far). Work it out again for the map we are on now, so the flight carries on all the way in.
            if fly.zoomIn and ns.CloseViewScale then
                local s = ns.CloseViewScale(newMap)
                if s then
                    local lo, hi = Limits()
                    fly.finalS = Clamp(s, lo, hi)
                    Trace(("FLY retarget on map %s: close-up %.4f, limits %.4f..%.4f -> final %.4f"):format(tostring(newMap), s, lo, hi, fly.finalS))
                    fly.midS = fly.finalS
                end
            end
        else
            fly = nil
        end
    end
    local u, v
    if anchored and ns.MapPoint then u, v = ns.MapPoint(oldMap, newMap, anchorU, anchorV) end
    if anchored and u and oldScale and oldScale > 0 and newScale and newScale > 0 then
        goalS = goalS * (newScale / oldScale)
        anchorU, anchorV = u, v
        ownS = newScale
        ownX, ownY = sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
        goalX, goalY = ownX, ownY
    else
        anchored = false
        ownS = newScale
        ownX, ownY = sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
        goalX, goalY, goalS = ownX, ownY, ownS
    end
    lastMapID = newMap
    -- SetMapID reset the game's own zoom/pan targets (to the new map's minimum / centre). Put them back
    -- equal to our state so the next frame doesn't take them for a request and glide to them.
    switchedAt = GetTime()
    sc.targetScale = ownS
    sc.targetScrollX, sc.targetScrollY = ownX, ownY
    if sc.SetZoomTarget then pcall(sc.SetZoomTarget, sc, ownS) end
    PutPanTarget(ownX, ownY)
    pendX, pendY = nil, nil   -- (the switch itself set the game's pan target: not a request)
end

-- Somebody just PLACED the view (e.g. MapMemory putting the map back where you left it when it opens): take
-- what the map shows now as our state, at once. Without this the new targets look like a request to go
-- there, and the view glides from where the map opened to the restored spot (a visible pan).
ns.AdoptMapView = function()
    if not (sc and Enabled() and WorldMapFrame:IsShown()) then return end
    fly = nil
    Adopt()
    PutPanTarget(ownX, ownY)
    pendX, pendY = nil, nil
    sc.targetScale = ownS
end

-- Fly the view to a spot (u, v) on the map being shown, ending at zoom finalS (nil = keep the zoom).
-- Pan and zoom glide together toward the target in one motion (no separate zoom-out phase).
ns.FlyTo = function(u, v, finalS, zoomIn)
    if not (sc and Enabled() and ownS and u and v) then return false end
    local W, H = sc.Child:GetWidth(), sc.Child:GetHeight()
    local viewW, viewH = sc:GetWidth(), sc:GetHeight()
    if not (W and W > 0 and H and H > 0 and viewW and viewW > 0) then return false end
    anchored, fly = false, nil
    local lo, hi = Limits()
    -- a close-up flight from a map with no world coordinates (the world map): head for its closest zoom;
    -- the hand-overs on the way in work out the real close-up for the map it ends on
    if zoomIn and not finalS then finalS = hi end
    finalS = Clamp(finalS or ownS, lo, hi)
    local dx, dy = (u - ownX) * W * ownS, (v - ownY) * H * ownS
    local dist = math.sqrt(dx * dx + dy * dy)
    Trace(("FLY to %.3f,%.3f  distance %.0f px (view %.0f px wide)  scale %.4f -> %.4f"):format(u, v, dist, viewW, ownS, finalS))
    fly = { tu = u, tv = v, midS = finalS, finalS = finalS, zoomIn = zoomIn }
    return true
end

-- Where the fly-to in progress is heading (map coordinates of the map being shown), or nil.
ns.SheetZoomFlying = function()
    if fly then return fly.tu, fly.tv end
end

-- Something else (middle-click centring) is about to move the view: drop our zoom so it isn't fought.
ns.CancelSheetZoom = function()
    anchored = false
    if ownS then goalS = ownS end
end

local function Apply()
    if not sc then return end
    if Enabled() then
        origWheel = origWheel or sc:GetScript("OnMouseWheel")
        sc:SetScript("OnMouseWheel", OnWheel)
        ownS = nil   -- adopt afresh
    elseif origWheel then
        sc:SetScript("OnMouseWheel", origWheel)
        ns:Print("Game zoom restored. /reload to bring back the other map hooks too.")
    end
end

ns:RegisterOption({
    key = "mapSheetZoom",
    type = "toggle",
    label = "Tile-map zoom and pan on the world map",
    tooltip = "Takes over the world map's view: smooth wheel zoom that keeps the spot under the cursor fixed, drag-panning with no limits, and no pull toward the middle of the map. Switching it off puts the game's own zoom back (a /reload restores everything).",
    default = true,
    onChange = Apply,
})

ns:RegisterOption({
    key = "mapExtraZoomIn",
    type = "text",
    label = "Extra map zoom-in (%), 0 = none",
    tooltip = "Lets you zoom in past the game's closest zoom. 100 = twice as close as normal, 200 = three times. Any number from 0 to 1000. Press Enter to save.",
    default = "0",
    maxLetters = 4,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    -- removed options (glide speed and zoom per scroll are fixed now)
    P13TweaksDB.mapZoomSmooth, P13TweaksDB.mapZoomStep, P13TweaksDB.mapZoomStepV = nil, nil, nil
    sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.InstantPanAndZoom and sc.GetNormalizedHorizontalScroll) then return end
    Apply()
    HookPanTarget()

    -- where the view and the cursor were when the left button went down (for dragging)
    sc:HookScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and ownS then
            dragPx, dragPy = GetCursorPosition()
            dragX, dragY = ownX, ownY
            downOnMap = true
        end
    end)

    -- HookScript: runs right AFTER the map's own per-frame update, so what we write is what gets drawn
    sc:HookScript("OnUpdate", function(_, dt)
        if not Enabled() then return end
        Frame(dt)
        -- then let the map level follow the view (zone <-> continent, neighbouring zones)
        -- (also while flying: centring on yourself from a continent or the world has to hand over to
        -- your zone on the way in, where the close-up zoom can be reached; OnMapSwitch carries the flight over)
        if ns.CheckMapLevels then ns.CheckMapLevels(sc) end
    end)
end)

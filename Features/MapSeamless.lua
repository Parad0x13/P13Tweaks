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
local lastWheelAny = 0   -- last time the wheel turned in either direction (debug log only)

-- Debug trace (P13TweaksDB.mapDebug): one line per event, newest 600 kept, saved on /reload.
local function Trace(text)
    if not (P13TweaksDB and P13TweaksDB.mapDebug) then return end
    local tr = P13TweaksDB.mapDebugTrace or {}
    P13TweaksDB.mapDebugTrace = tr
    tr[#tr + 1] = ("%.2f %s"):format(GetTime() % 1000, text)
    if #tr > 600 then table.remove(tr, 1) end
end
ns.MapTrace = Trace
-- Where the mouse is: on screen (pixels from the map area's top-left) and on the map (0-1).
local function MouseText(sc)
    local cx, cy = GetCursorPosition()
    local s = sc:GetEffectiveScale()
    local l, t = sc:GetLeft(), sc:GetTop()
    local u, v = nil, nil
    if sc.GetNormalizedCursorPosition and sc:IsMouseOver() then u, v = sc:GetNormalizedCursorPosition() end
    return ("mouse px %d,%d map %s,%s"):format(l and (cx / s - l) or -1, t and (t - cy / s) or -1,
        u and ("%.3f"):format(u) or "off", v and ("%.3f"):format(v) or "off")
end

-- Let the view sit up to half a view past the map's edge, always (not just while scrolling:
-- when the extra room closed again the game slid the view back toward the land, a snap). So
-- zooming near the coast keeps your spot where it is and the empty sea past the edge is just
-- allowed to show, instead of the game sliding the view inland to avoid it.
local EDGE_ROOM = 0.5
local function EdgeRoom()
    return (P13TweaksDB and P13TweaksDB.mapNoEdgeRoom) and 0 or EDGE_ROOM
end

-- The game keeps the limits in sc.scrollXExtentsMin/Max and sc.scrollYExtentsMin/Max and sets
-- them itself every time the zoom changes (a trace showed them shrinking with each step; it
-- never goes through its CalculateScrollExtents functions while zooming). So widen them right
-- after it does. `widened` remembers what we last wrote, so we never add the room twice.
local widened
local function WidenLimits(sc)
    local room = EdgeRoom()
    local a, b, c, d = sc.scrollXExtentsMin, sc.scrollXExtentsMax, sc.scrollYExtentsMin, sc.scrollYExtentsMax
    if room <= 0 or not (a and b and c and d) then return end
    if widened and math.abs(a - widened[1]) < 1e-7 and math.abs(b - widened[2]) < 1e-7
        and math.abs(c - widened[3]) < 1e-7 and math.abs(d - widened[4]) < 1e-7 then
        return   -- the game hasn't recomputed them since we widened them
    end
    sc.scrollXExtentsMin, sc.scrollXExtentsMax = a - room, b + room
    sc.scrollYExtentsMin, sc.scrollYExtentsMax = c - room, d + room
    widened = { a - room, b + room, c - room, d + room }
end
ns.WidenMapLimits = WidenLimits   -- MapSheetZoom uses the same one, so the room is never added twice

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

-- A point (u, v) on one map, expressed on another that is its parent, its child, or its sibling
-- (same parent). Used to carry the zoom's state across a hand-over.
local function MapPoint(fromMap, toMap, u, v, depth)
    if fromMap == toMap then return u, v end
    depth = depth or 0
    if depth > 3 then return end
    local fi, ti = C_Map.GetMapInfo(fromMap), C_Map.GetMapInfo(toMap)
    local pf, pt = fi and fi.parentMapID, ti and ti.parentMapID
    -- one step up or down
    if pf and pf == toMap then
        local minX, minY, rw, rh = Rect(fromMap, pf)
        if minX then return minX + u * rw, minY + v * rh end
        return
    elseif pt and pt == fromMap then
        local minX, minY, rw, rh = Rect(toMap, pt)
        if minX then return (u - minX) / rw, (v - minY) / rh end
        return
    end
    -- further away (a sibling, a grandparent...): go up a level from here, then carry on
    if pf and pf ~= 0 then
        local pu, pv = MapPoint(fromMap, pf, u, v, depth + 1)
        if pu then return MapPoint(pf, toMap, pu, pv, depth + 1) end
    end
end
ns.MapPoint = MapPoint

-- The game sizes the player arrow as about 27 / canvasScale (so it stays ~27 px on screen) whenever it
-- hears the canvas scale changed. We write the scale ourselves (and set it again after a level switch),
-- so make the arrow re-measure against the final scale right away, or it can show for a frame at a
-- size worked out for the old scale (a giant arrow).
local playerPin
local pinLogLine   -- set below by the pindebug diagnostic
function ns.SyncPlayerPin()
    if not playerPin and WorldMapFrame.EnumeratePinsByTemplate then
        for pin in WorldMapFrame:EnumeratePinsByTemplate("GroupMembersPinTemplate") do playerPin = pin break end
    end
    if not playerPin then return end
    -- The game also "pings" the arrow (a huge copy shrinking onto you) when the map changes. Those
    -- methods live on the widget, not the pin table, so they were never wrapped before. Skip a ping that
    -- our own level switches cause; log every ping call for /p13 pindebug.
    if not playerPin.p13PingHooked then
        playerPin.p13PingHooked = true
        for _, name in ipairs({ "StartPlayerPing", "StopPlayerPing", "SetPlayerPingScale", "SetPlayerPingTexture" }) do
            local orig = playerPin[name]
            if orig then
                playerPin[name] = function(self, ...)
                    local ours = ns.suppressMapRing or GetTime() - lastSwitch < 0.6
                    -- (routine scale updates are only logged around a level switch, or the log fills up)
                    if pinLogLine and (ours or name ~= "SetPlayerPingScale") then
                        pinLogLine(("%s(%s) %s"):format(name, tostring((...)), ours and "SUPPRESSED" or "allowed"))
                    end
                    if ours and name == "StartPlayerPing" then return end
                    return orig(self, ...)
                end
            end
        end
    end
    if playerPin.OnCanvasScaleChanged then pcall(playerPin.OnCanvasScaleChanged, playerPin) end
end

-- Every pin on the map (not just the arrow: anvils, quest icons...) works its on-screen size out from the
-- canvas zoom. After a level switch, make all of them re-measure against the final zoom.
function ns.SyncAllPins()
    ns.SyncPlayerPin()
    if not WorldMapFrame.EnumerateAllPins then return end
    for pin in WorldMapFrame:EnumerateAllPins() do
        if pin ~= playerPin then
            if pin.OnCanvasScaleChanged then pcall(pin.OnCanvasScaleChanged, pin) end
            if pin.ApplyCurrentScale then pcall(pin.ApplyCurrentScale, pin) end
        end
    end
end

-- Diagnostic for the player-arrow flicker: /p13 pindebug lists the player pin's ping/size/scale methods
-- and prints each call (at most one line per method per 0.1 s) with the canvas scale and map.
local pinLog, pinLast, pinPlayerSize = false, {}, nil
pinLogLine = function(text)
    if not pinLog then return end
    P13TweaksDB.pinLog = P13TweaksDB.pinLog or {}
    if #P13TweaksDB.pinLog < 800 then
        table.insert(P13TweaksDB.pinLog, ("%.2f %s  canvasScale %.4f  map %s"):format(
            GetTime(), text, WorldMapFrame:GetCanvasScale(), tostring(WorldMapFrame:GetMapID())))
    end
end
-- every rendered frame while logging: is the arrow's last size still right for the current scale?
-- (size x scale should stay about 27; anything else means a frame of wrong-sized arrow)
local pinCheck = CreateFrame("Frame")
pinCheck:SetScript("OnUpdate", function()
    if not (pinLog and pinPlayerSize and WorldMapFrame:IsShown()) then return end
    local px = pinPlayerSize * WorldMapFrame:GetCanvasScale()
    if px < 20 or px > 35 then
        P13TweaksDB.pinLog = P13TweaksDB.pinLog or {}
        if #P13TweaksDB.pinLog < 800 then
            table.insert(P13TweaksDB.pinLog, ("%.2f MISMATCH arrow shows %.0f px (size %.3f x canvasScale %.4f)  map %s"):format(
                GetTime(), px, pinPlayerSize, WorldMapFrame:GetCanvasScale(), tostring(WorldMapFrame:GetMapID())))
        end
    end
end)
ns:RegisterCommand("pindebug", "log the player arrow's ping/size/scale calls (flicker hunting)", function()
    pinLog = not pinLog
    if not WorldMapFrame.EnumeratePinsByTemplate then ns:Print("no EnumeratePinsByTemplate here") return end
    for pin in WorldMapFrame:EnumeratePinsByTemplate("GroupMembersPinTemplate") do
        if not pin.p13Spy then
            pin.p13Spy = true
            local names = {}
            for k, v in pairs(pin) do
                if type(v) == "function" and type(k) == "string" and (k:find("Ping") or k:find("Size") or k:find("Scale")) then
                    names[#names + 1] = k
                    pin[k] = function(self, ...)
                        if k == "SetPinSize" and (...) == "player" then pinPlayerSize = (select(2, ...)) end
                        if pinLog and (k == "SetPinSize" or k == "SetScaleStyle" or k == "ApplyCurrentScale")
                            and (ns.suppressMapRing or GetTime() - lastSwitch < 0.6) then   -- only around a level switch
                            -- saved to the SavedVariables file on /reload or logout (chat can't be copied)
                            P13TweaksDB.pinLog = P13TweaksDB.pinLog or {}
                            local log = P13TweaksDB.pinLog
                            if #log < 800 then
                                local args = {}
                                for i = 1, select("#", ...) do args[i] = tostring((select(i, ...))) end
                                local sc2 = WorldMapFrame.ScrollContainer
                                log[#log + 1] = ("%.2f %s(%s)  canvasScale %.4f (min %.4f max %.4f)  frameScale %.3f  map %s"):format(
                                    GetTime(), k, table.concat(args, ", "), WorldMapFrame:GetCanvasScale(),
                                    sc2.GetScaleForMinZoom and sc2:GetScaleForMinZoom() or -1,
                                    sc2.GetScaleForMaxZoom and sc2:GetScaleForMaxZoom() or -1,
                                    self:GetScale() or -1, tostring(WorldMapFrame:GetMapID()))
                            end
                        end
                        return v(self, ...)
                    end
                end
            end
            table.sort(names)
            P13TweaksDB.pinMethods = table.concat(names, ", ")   -- saved too
            ns:Print("player pin methods watched: " .. P13TweaksDB.pinMethods)
        end
    end
    if pinLog then P13TweaksDB.pinLog = {} end   -- each run starts a fresh log
    ns:Print("pin logging " .. (pinLog and "ON (log is saved on /reload)" or ("OFF - " .. #(P13TweaksDB.pinLog or {}) .. " lines logged, /reload to save")))
end)

-- Switch maps without the "map changed" ring and with our own zoom applied straight away.
local function SwitchTo(mapID, scale, x, y)
    local sc = WorldMapFrame.ScrollContainer
    local oldMap, oldScale = WorldMapFrame:GetMapID(), sc:GetCanvasScale()
    -- The game limits how far the view may sit off-centre on the new map (a zoomed-out zone can
    -- only sit centred) and quietly moves it: the visible jump at hand-over. Open the limits up
    -- (see EDGE_ROOM) and place the view exactly where we ask.
    lastSwitch = GetTime()   -- (early, so the pindebug window covers the whole switch)
    ns.suppressMapRing = true
    ns.SyncPlayerPin()   -- (also installs the ping guard before the map changes)
    if pinLogLine then pinLogLine(("SWITCH %s -> %s  (scale %.4f -> wanted %.4f)"):format(tostring(oldMap), tostring(mapID), oldScale, scale)) end
    WorldMapFrame:SetMapID(mapID)
    if pinLogLine then pinLogLine("SWITCH done SetMapID") end
    ns.suppressMapRing = false
    sc:InstantPanAndZoom(scale, x, y, true)
    -- The new map's limits were just set by the game; open them up and put the view exactly
    -- where the old map showed it (setting the scroll directly, so the limits aren't redone).
    WidenLimits(sc)
    if sc.SetNormalizedHorizontalScroll and sc.SetNormalizedVerticalScroll then
        sc:SetNormalizedHorizontalScroll(x)
        sc:SetNormalizedVerticalScroll(y)
    end
    if sc.SetPanTarget then sc:SetPanTarget(x, y) end
    ns.SyncAllPins()
    if pinLogLine then
        pinLogLine(("SWITCH end: canvas %.4f childScale %.4f  arrow size %s -> %.1f px on screen"):format(
            sc:GetCanvasScale(), sc.Child and sc.Child:GetScale() or -1, tostring(pinPlayerSize), (pinPlayerSize or 0) * sc:GetCanvasScale()))
    end
    lastSwitch = GetTime()
    if ns.RefreshMapTerrain then ns.RefreshMapTerrain(true) end
    if ns.RedrawMapDrawings then ns.RedrawMapDrawings() end   -- the lines for the new map, this same frame
    -- let the tile-map zoom carry its state (target zoom, the spot under the cursor) to the new map
    if ns.OnMapSwitch then ns.OnMapSwitch(oldMap, mapID, oldScale, sc:GetCanvasScale()) end
    if P13TweaksDB and P13TweaksDB.mapDebug then
        -- wanted vs. what the game actually applied (it clamps to the new map's limits)
        local line = ("-> %s  wanted scale %.4f at %.3f,%.3f  got scale %.4f (target %.4f) at %.3f,%.3f  min %.4f max %.4f"):format(
            tostring(mapID), scale, x, y, sc:GetCanvasScale(), sc.targetScale or -1,
            sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll(),
            sc.GetScaleForMinZoom and sc:GetScaleForMinZoom() or -1, sc.GetScaleForMaxZoom and sc:GetScaleForMaxZoom() or -1)
        -- saved to the SavedVariables file on /reload or logout, so it can be read without copying chat
        P13TweaksDB.mapDebugLog = P13TweaksDB.mapDebugLog or {}
        local function ext() return ("ext x %.3f..%.3f y %.3f..%.3f"):format(
            sc.scrollXExtentsMin or -1, sc.scrollXExtentsMax or -1, sc.scrollYExtentsMin or -1, sc.scrollYExtentsMax or -1) end
        table.insert(P13TweaksDB.mapDebugLog, "v" .. (ns.version or "?") .. " " .. line .. "  " .. ext())
        -- and where the view is shortly afterwards, to catch it moving on its own
        C_Timer.After(0.5, function()
            table.insert(P13TweaksDB.mapDebugLog, ("   0.5s later: scale %.4f at %.3f,%.3f  %s"):format(
                sc:GetCanvasScale(), sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll(), ext()))
        end)
    end
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
    if ns.sheetZoomActive and ns.sheetZoomActive() then return end
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
-- Dragging past a zone's edge: a zone map ends at its border, so the game won't drag any
-- further. Keep pushing and we hand over to the continent at the same zoom and spot, and
-- the drag carries on there.
---------------------------------------------------------------------------

local EDGE_PUSH_PIXELS = 40   -- how far you have to drag into the edge before it hands over
local EDGE_EPS = 0.0005
local pushed, lastCX, lastCY = 0, nil, nil

local function ParentSameView(sc)
    local mapID = WorldMapFrame:GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    local parent = info and info.parentMapID
    if not parent or parent == 0 or (Enum.UIMapType and info.mapType < Enum.UIMapType.Zone) then return end
    local minX, minY, rw, rh = Rect(mapID, parent)
    if not (minX and Art(mapID) and Art(parent)) then return end
    local cx, cy = ViewCentre(sc)
    SwitchTo(parent, ParentScaleFromChild(sc:GetCanvasScale(), mapID, parent), minX + cx * rw, minY + cy * rh)
    return true
end

local function CheckEdgePush(sc)
    local cx, cy = GetCursorPosition()
    local px, py = lastCX, lastCY
    lastCX, lastCY = cx, cy
    local lb = sc.mouseButtonInfo and sc.mouseButtonInfo.LeftButton
    if not (ns:Get("mapSeamless") and px and lb and lb.down and sc.IsPanning and sc:IsPanning()
        and sc.targetScrollX and sc.scrollXExtentsMin) then
        pushed = 0
        return
    end
    -- the game's own sign: dragging the mouse left moves the view right, etc.
    local dx, dy = px - cx, cy - py
    local push = 0
    local room = EdgeRoom()   -- the limits are widened by this; the zone's real edge is inside them
    if dx > 0 and sc.targetScrollX >= sc.scrollXExtentsMax - room - EDGE_EPS then push = push + dx end
    if dx < 0 and sc.targetScrollX <= sc.scrollXExtentsMin + room + EDGE_EPS then push = push - dx end
    if dy > 0 and sc.targetScrollY >= sc.scrollYExtentsMax - room - EDGE_EPS then push = push + dy end
    if dy < 0 and sc.targetScrollY <= sc.scrollYExtentsMin + room + EDGE_EPS then push = push - dy end
    pushed = push > 0 and pushed + push / sc:GetEffectiveScale() or 0
    if pushed >= EDGE_PUSH_PIXELS and GetTime() - lastSwitch >= SWITCH_COOLDOWN then
        pushed = 0
        ParentSameView(sc)
    end
end

---------------------------------------------------------------------------
-- Map levels follow the view (used with the tile-map zoom, which has no wheel hand-overs):
--  * zoomed out until the view is wider than this zone/continent -> its parent, same view
--  * the middle of the view moves into a neighbouring zone        -> that zone, same view
--  * zoomed in on a continent until a zone fills the view         -> that zone, same view
-- Switching up needs the view 10% wider than the map; switching down needs the zone to fill the
-- view, so there is a gap between the two and it never flips back and forth.
---------------------------------------------------------------------------

local glideX, glideY   -- where the view was the last time we looked (to tell whether it's moving)
local function CheckMapLevels(sc)
    if not (ns:Get("mapSeamless") and WorldMapFrame:IsShown()) then return end
    if GetTime() - lastSwitch < SWITCH_COOLDOWN then return end
    -- Not while the map is being dragged: changing maps ends the game's drag (it started on the old
    -- map), and panning then stays dead until you click again. The switch happens when you let go.
    if (sc.IsPanning and sc:IsPanning()) or (IsMouseButtonDown("LeftButton") and sc:IsMouseOver()) then return end
    local mapID = WorldMapFrame:GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not (info and info.mapType and info.mapType >= 1 and info.mapType <= 3) then return end   -- world, continent, zone
    local scale = sc:GetCanvasScale()
    if not (scale and scale > 0 and scale < math.huge) then return end
    local cx, cy = ViewCentre(sc)
    -- Not while the view is still gliding to a target (centring on yourself, say): switching maps
    -- re-aims the glide at the current spot and it stops half way. Wait until it has arrived.
    -- (only if the view is really moving: a target it can't reach mustn't block this for good)
    local moving = glideX and (math.abs(cx - glideX) > 0.0003 or math.abs(cy - glideY) > 0.0003)
    glideX, glideY = cx, cy
    if moving and sc.targetScrollX and (math.abs(sc.targetScrollX - cx) > 0.003 or math.abs((sc.targetScrollY or cy) - cy) > 0.003) then return end
    if sc.targetScale and math.abs(sc.targetScale - scale) > scale * 0.002 then return end
    local parent = info.parentMapID

    if parent and parent ~= 0 and info.mapType >= 2 then
        local minX, minY, rw, rh = Rect(mapID, parent)
        if minX and Art(mapID) and Art(parent) then
            local pScale = ParentScaleFromChild(scale, mapID, parent)
            local fit = FitScale(mapID, parent)
            -- 1. zoomed out past the whole map
            if fit and pScale <= fit * 0.9 then
                Trace(("LEVEL up %s -> %s  (scale %.4f, parent scale %.4f, fit %.4f)"):format(mapID, parent, scale, pScale, fit))
                SwitchTo(parent, pScale, minX + cx * rw, minY + cy * rh)
                return
            end
            -- 2. the middle of the view is over a neighbouring map
            local pu, pv = minX + cx * rw, minY + cy * rh
            local sib = ChildAt(parent, pu, pv)
            if sib and sib ~= mapID then
                local sMinX, sMinY, sw, sh = Rect(sib, parent)
                if sMinX and Art(sib) then
                    local nu = math.min(math.max((pu - sMinX) / sw, 0), 1)
                    local nv = math.min(math.max((pv - sMinY) / sh, 0), 1)
                    Trace(("LEVEL sideways %s -> %s  (view %.3f,%.3f)"):format(mapID, sib, cx, cy))
                    SwitchTo(sib, ChildScaleFromParent(pScale, sib, parent), nu, nv)
                    return
                end
            end
        end
    end

    -- 3. a map below this one fills the view
    if info.mapType <= 2 then
        local child = ChildAt(mapID, cx, cy)
        local fit = child and FitScale(child, mapID)
        if fit and scale >= fit * 0.98 then
            Trace(("LEVEL down %s -> %s  (scale %.4f, fit %.4f)"):format(mapID, child, scale, fit))
            EnterChild(sc, mapID, child)
        end
    end
end
ns.CheckMapLevels = CheckMapLevels

---------------------------------------------------------------------------
-- Mouse wheel
---------------------------------------------------------------------------

-- Where the zoom was heading as of the last frame, i.e. before this wheel turn changed it.
local prevTargetScale
local function WasAtMaxZoom(sc)
    if not (sc.GetScaleForMaxZoom and prevTargetScale) then return IsFullyZoomedIn(sc) end
    return prevTargetScale >= sc:GetScaleForMaxZoom() - 0.001
end

-- Where the view's centre was just before this scroll (updated every frame). The game moves the
-- view itself while handling a scroll, clamping it to its own narrow limits, so by the time we run
-- the view has already snapped (seen in the trace: y 0.337 -> 0.363 -> 0.426 on the way out).
-- We work from where it was before instead.
local preX, preY

-- Zoom from scale s0 to s1 keeping the map point under the mouse where it is on screen, computed
-- from the view as it was before the scroll, and place the view there straight away.
local function AnchorZoom(sc, s0, s1)
    if not (preX and s0 and s1 and s0 > 0 and s1 > 0 and sc.Child) then return end
    local W, H = sc.Child:GetWidth(), sc.Child:GetHeight()
    local l, r, t, b = sc:GetLeft(), sc:GetRight(), sc:GetTop(), sc:GetBottom()
    if not (W and W > 0 and H and H > 0 and l and r and t and b) then return end
    local cx, cy = GetCursorPosition()
    local es = sc:GetEffectiveScale()
    local px, py = cx / es, cy / es
    local ax, ay = preX, preY   -- mouse outside the map: zoom about the middle of the view
    if px >= l and px <= r and py >= b and py <= t then
        ax = preX + (px - (l + r) / 2) / (s0 * W)
        ay = preY - (py - (t + b) / 2) / (s0 * H)
    end
    local k = s0 / s1
    local nx, ny = ax + (preX - ax) * k, ay + (preY - ay) * k
    if sc.SetNormalizedHorizontalScroll and sc.SetNormalizedVerticalScroll then
        sc:SetNormalizedHorizontalScroll(nx)
        sc:SetNormalizedVerticalScroll(ny)
    end
    if sc.SetPanTarget then sc:SetPanTarget(nx, ny) end
    preX, preY = nx, ny   -- another turn in the same frame builds on this one
    prevTargetScale = s1
end

local function OnWheel(sc, delta)
    if ns.sheetZoomActive and ns.sheetZoomActive() then return end   -- tile-map zoom has taken over the wheel
    lastWheelAny = GetTime()
    WidenLimits(sc)   -- the game just recomputed them for the new zoom
    Trace(("WHEEL %s  map %s scale %.4f->%.4f  view %.3f,%.3f  %s"):format(delta > 0 and "IN" or "OUT",
        tostring(WorldMapFrame:GetMapID()), sc:GetCanvasScale(), sc.targetScale or -1,
        sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll(), MouseText(sc)))
    if delta > 0 then
        lastWheelIn = GetTime()
        if not WasAtMaxZoom(sc) then
            AnchorZoom(sc, prevTargetScale, sc.targetScale or sc:GetCanvasScale())
            return
        end
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

    -- Normal scroll out: pull back around the cursor (see AnchorZoom).
    AnchorZoom(sc, prevTargetScale, sc.targetScale or sc:GetCanvasScale())
end

ns:RegisterOption({
    key = "mapSeamless",
    type = "toggle",
    label = "Seamless map zoom (world, continent, zone)",
    tooltip = "Zoom straight through map levels as if they were one map: zooming in on a continent hands over to the zone in the middle of the view, and zooming out of a zone hands over to its continent, at the same scale and spot. Dragging past the edge of a zone carries on onto the continent map.",
    default = true,
    onChange = function()
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        -- sc.mapID, not WorldMapFrame's: a fresh character's scroll area may have no map yet
        -- (the new zoom then applies when the map next loads)
        if sc and sc.CreateZoomLevels and sc.mapID then sc:CreateZoomLevels() end
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
        -- sc.mapID, not WorldMapFrame's: a fresh character's scroll area may have no map yet
        -- (the new zoom then applies when the map next loads)
        if sc and sc.CreateZoomLevels and sc.mapID then sc:CreateZoomLevels() end
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
        -- sc.mapID, not WorldMapFrame's: a fresh character's scroll area may have no map yet
        -- (the new zoom then applies when the map next loads)
        if sc and sc.CreateZoomLevels and sc.mapID then sc:CreateZoomLevels() end
    end,
})

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", function()
    -- tidy up settings from the older jump-up-a-map options this replaces
    P13TweaksDB.mapZoomOutParent, P13TweaksDB.mapParentCentre, P13TweaksDB.mapZoomOutCentre = nil, nil, nil
    P13TweaksDB.mapDebugTrace, P13TweaksDB.mapDebugCalls = nil, nil   -- each session's debug trace starts fresh
    -- Test switches from earlier versions were saved between sessions and silently kept the new
    -- edge room (and the other fixes) switched off. They are session-only now: always clear them.
    P13TweaksDB.mapNoEdgeRoom, P13TweaksDB.mapNoSteer, P13TweaksDB.mapNoHold = nil, nil, nil

    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.InstantPanAndZoom and sc.GetNormalizedHorizontalScroll) then return end
    sc:HookScript("OnMouseWheel", OnWheel)

    if P13TweaksDB and P13TweaksDB.mapDebug then
        -- list the map scroll area's methods and fields, to find what limits the view's position
        local names = {}
        local mt = getmetatable(sc)
        local idx = mt and type(mt.__index) == "table" and mt.__index
        for k, v in pairs(idx or {}) do
            if type(k) == "string" and (k:find("Extent") or k:find("Scroll") or k:find("Pan") or k:find("Zoom") or k:find("Clamp") or k:find("Update")) then
                names[#names + 1] = k .. " (" .. type(v) .. ")"
            end
        end
        for k, v in pairs(sc) do
            if type(k) == "string" and (k:find("xtent") or k:find("target") or k:find("Target") or k:find("zoom") or k:find("scroll")) then
                names[#names + 1] = "field " .. k .. " = " .. tostring(v)
            end
        end
        table.sort(names)
        P13TweaksDB.mapDebugFuncs = names
    end
    if sc.CreateZoomLevels then hooksecurefunc(sc, "CreateZoomLevels", AdjustZoomLevels) end

    -- Watch the zoom while the map is open, to hand over to a zone once it fills the view.
    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function()
        prevTargetScale = sc.targetScale or sc:GetCanvasScale()
        WidenLimits(sc)
        if P13TweaksDB and P13TweaksDB.mapDebug and GetTime() - lastWheelAny < 2 then
            -- after a scroll, a line whenever the view, zoom or limits change; a jump of the view's
            -- centre of more than 0.02 in one frame is marked "SNAP"
            local vx, vy = sc:GetNormalizedHorizontalScroll(), sc:GetNormalizedVerticalScroll()
            local snap = ns.lastViewX and (math.abs(vx - ns.lastViewX) > 0.02 or math.abs(vy - ns.lastViewY) > 0.02)
            ns.lastViewX, ns.lastViewY = vx, vy
            local body = ("map %s scale %.4f->%.4f  view %.3f,%.3f -> %s,%s  ext x %s..%s y %s..%s  %s"):format(
                tostring(WorldMapFrame:GetMapID()), sc:GetCanvasScale(), sc.targetScale or -1, vx, vy,
                sc.targetScrollX and ("%.3f"):format(sc.targetScrollX) or "?",
                sc.targetScrollY and ("%.3f"):format(sc.targetScrollY) or "?",
                sc.scrollXExtentsMin and ("%.3f"):format(sc.scrollXExtentsMin) or "?",
                sc.scrollXExtentsMax and ("%.3f"):format(sc.scrollXExtentsMax) or "?",
                sc.scrollYExtentsMin and ("%.3f"):format(sc.scrollYExtentsMin) or "?",
                sc.scrollYExtentsMax and ("%.3f"):format(sc.scrollYExtentsMax) or "?", MouseText(sc))
            if body ~= ns.lastTraceBody or snap then
                ns.lastTraceBody = body
                Trace((snap and "SNAP " or "     ") .. body)
            end
        end
        CheckZoomIn()
        if not (ns.sheetZoomActive and ns.sheetZoomActive()) then CheckEdgePush(sc) end   -- the tile-map zoom switches levels by the view instead
        preX, preY = ViewCentre(sc)
    end)
end)

-- P13Tweaks feature: double-click the world map to plan a route there.
--   * The route: walk straight there, or walk to a flight master you've unlocked, fly to the
--     unlocked flight point nearest the destination and walk the rest - whichever is quicker.
--   * Drawn on the map: dashed lines = walking, solid blue = flying, a star at the destination.
--   * The game's own waypoint + arrow points at your next stop (the flight master, or the
--     destination). After you land it re-plans; when you arrive the route clears itself.
-- Addons can't see the game's pathfinding, so walking legs are straight lines (not around
-- hills or walls). Flights assume every flight point you know connects (true in Classic).
-- World coordinates here: X = north-south, Y = west-east, as UnitPosition returns them.
local ADDON_NAME, ns = ...

local MAP_TYPE_CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
local FOOT_SPEED     = 7      -- yards/second running
local FLY_SPEED      = 30     -- yards/second on a flight path (roughly)
local FLY_DETOUR     = 1.25   -- flight paths aren't straight
local FLY_OVERHEAD   = 25     -- seconds: talking to the flight master, take-off, landing
local ARRIVE_YARDS   = 25
local DOUBLE_CLICK   = 0.4    -- seconds between the two clicks
local DOUBLE_PIXELS  = 12     -- the two clicks must be this close on screen
local STAR_PIXELS    = 16     -- double-click this close to the destination star removes the route
local DASH, GAP      = 10, 6  -- dashed walking lines, in screen pixels
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"

-- (all file-level locals up here, before any function uses them)
local routeLayer, clearButton, star
local linePool, linesUsed = {}, 0
local route          -- { inst, dest = { X, Y, map, contMap, name }, legs = { { kind, from, to, label } }, total, direct }
local lastDown       -- { t, x, y (screen), mapID, mx, my (map) }
local lastSig
local wasOnTaxi = false
local boundsCache = {}
local ourPoint       -- the waypoint we last set: { m, u, v } - to tell ours from yours
local ClearRoute     -- (defined further down; used by the waypoint watcher)

local function On() return ns:Get("mapRoute") end
local function IsSecret(v) return issecretvalue and issecretvalue(v) end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

-- A map's world corners: { inst, top, left, bottom, right } or false.
local function Bounds(mapID)
    if boundsCache[mapID] ~= nil then return boundsCache[mapID] end
    local r = false
    if mapID and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local c1, tl = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local c2, br = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
        if c1 and c1 == c2 and tl and br then
            local top, left = tl:GetXY()
            local bottom, right = br:GetXY()
            if top ~= bottom and left ~= right then
                r = { inst = c1, top = top, left = left, bottom = bottom, right = right }
            end
        end
    end
    boundsCache[mapID] = r
    return r
end

local function ToWorld(mapID, x, y)
    local b = Bounds(mapID)
    if not b then return end
    return b.inst, b.top - y * (b.top - b.bottom), b.left - x * (b.left - b.right)
end

-- Map position (may be outside 0-1 when the point is off that map), or nil if another world.
local function ToMap(mapID, inst, X, Y)
    local b = Bounds(mapID)
    if not b or b.inst ~= inst then return end
    return (b.left - Y) / (b.left - b.right), (b.top - X) / (b.top - b.bottom)
end

local function Dist(X1, Y1, X2, Y2) return math.sqrt((X1 - X2) ^ 2 + (Y1 - Y2) ^ 2) end

local function ContinentMap(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    while info do
        if info.mapType == MAP_TYPE_CONTINENT then return info.mapID end
        if not info.parentMapID or info.parentMapID == 0 then return end
        info = C_Map.GetMapInfo(info.parentMapID)
    end
end

local function PlayerWorld()
    local X, Y, _, inst = UnitPosition("player")
    if X == nil or IsSecret(X) or IsSecret(Y) then return end
    return X, Y, inst
end

-- Running speed, or your mount's if we've seen you riding (remembered per character).
local function TravelSpeed()
    local key = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    local s = P13TweaksDB.routeMountSpeed and P13TweaksDB.routeMountSpeed[key]
    return (s and s > FOOT_SPEED) and s or FOOT_SPEED
end

local function NoteSpeed()
    if not (IsMounted and IsMounted()) or UnitOnTaxi("player") then return end
    local s = GetUnitSpeed and GetUnitSpeed("player")
    if not s or IsSecret(s) or s <= FOOT_SPEED or s > 30 then return end
    local key = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    P13TweaksDB.routeMountSpeed = P13TweaksDB.routeMountSpeed or {}
    P13TweaksDB.routeMountSpeed[key] = s
end

local function Duration(sec)
    if sec >= 90 then return ("%d min"):format(math.floor(sec / 60 + 0.5)) end
    return ("%d s"):format(math.floor(sec + 0.5))
end

---------------------------------------------------------------------------
-- The game's waypoint + arrow
---------------------------------------------------------------------------

local function SetWaypoint(inst, X, Y, hintMap)
    if not (C_Map.SetUserWaypoint and UiMapPoint) then return end
    local candidates = {}
    -- the zone under the point (waypoints go on zone maps)
    local cont = ContinentMap(hintMap)
    if cont and C_Map.GetMapInfoAtPosition then
        local u, v = ToMap(cont, inst, X, Y)
        local info = u and C_Map.GetMapInfoAtPosition(cont, u, v)
        if info then table.insert(candidates, info.mapID) end
    end
    if hintMap then table.insert(candidates, hintMap) end
    for _, m in ipairs(candidates) do
        local u, v = ToMap(m, inst, X, Y)
        if u and u >= 0 and u <= 1 and v >= 0 and v <= 1
            and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(m)) then
            ourPoint = { m = m, u = u, v = v }   -- before setting: the change event may fire right away
            if pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(m, u, v)) then
                if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
                end
                return true
            end
        end
    end
end

local function ClearWaypoint()
    ourPoint = nil
    if C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end

-- The game's waypoint changed. Removed -> end the route. Replaced by one that isn't ours
-- (you placed a pin, or another feature did) -> end the route but keep that pin.
local function OnWaypointChanged()
    if not route or not C_Map.HasUserWaypoint then return end
    if not C_Map.HasUserWaypoint() then
        ourPoint = nil
        -- The game removes a waypoint by itself once you reach it. At a stop along the way
        -- (the flight master) that's not "you removed it": keep the route going.
        local next = route.next
        if next and next ~= route.dest then
            local X, Y, inst = PlayerWorld()
            if X and inst == route.dest.inst and Dist(X, Y, next.X, next.Y) <= 60 then return end
        end
        ClearRoute(nil, true)
        return
    end
    local p = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
    local x, y
    -- (plain fields: this position's GetXY errors on Forever)
    if p and p.position then x, y = tonumber(p.position.x), tonumber(p.position.y) end
    if ourPoint and p and x and (p.uiMapID ~= ourPoint.m or math.abs(x - ourPoint.u) > 0.002
        or math.abs(y - ourPoint.v) > 0.002) then
        ourPoint = nil
        ClearRoute(nil, true)
    end
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

-- Flight points this character has unlocked on a continent: { name, X, Y }.
local function KnownFlights(contMap, inst)
    local list = {}
    if not (contMap and C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap and ns.IsFlightKnown) then return list end
    for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(contMap) or {}) do
        if node.name and node.position and ns.IsFlightKnown(node.name) then
            local i, X, Y = ToWorld(contMap, node.position.x, node.position.y)
            if i == inst then table.insert(list, { name = node.name, X = X, Y = Y }) end
        end
    end
    return list
end

local function ShortName(name) return (name or "?"):match("^([^,]+)") or name end

local function Plan(quiet)
    lastSig = nil
    if not route then return end
    local dest = route.dest
    local X, Y, inst = PlayerWorld()
    if not X then return end
    route.legs = {}
    if inst ~= dest.inst then
        route.other = true
        SetWaypoint(dest.inst, dest.X, dest.Y, dest.map)
        if not quiet then ns:Print("Route: that's on another continent - waypoint set; take a boat or zeppelin first.") end
        return
    end
    route.other = nil

    local speed = TravelSpeed()
    local direct = Dist(X, Y, dest.X, dest.Y) / speed
    local best, bestA, bestB = direct
    local flights = KnownFlights(dest.contMap, inst)
    for _, A in ipairs(flights) do
        local toA = Dist(X, Y, A.X, A.Y) / speed
        if toA < best then
            for _, B in ipairs(flights) do
                if B ~= A then
                    local t = toA + FLY_OVERHEAD + FLY_DETOUR * Dist(A.X, A.Y, B.X, B.Y) / FLY_SPEED
                        + Dist(B.X, B.Y, dest.X, dest.Y) / speed
                    if t < best then best, bestA, bestB = t, A, B end
                end
            end
        end
    end
    route.total, route.direct = best, direct

    local here = { X = X, Y = Y }
    if bestA then
        route.legs = {
            { kind = "walk", from = here, to = bestA, follow = true },
            { kind = "fly", from = bestA, to = bestB },
            { kind = "walk", from = bestB, to = dest },
        }
        route.next = bestA
        SetWaypoint(inst, bestA.X, bestA.Y, dest.contMap or dest.map)
        if not quiet then
            ns:Print(("Route to %s: go to the flight master at %s, fly to %s, then walk %d yards. About %s (on foot/mount all the way: %s)."):format(
                dest.name, ShortName(bestA.name), ShortName(bestB.name),
                math.floor(Dist(bestB.X, bestB.Y, dest.X, dest.Y)), Duration(best), Duration(direct)))
        end
    else
        route.legs = { { kind = "walk", from = here, to = dest, follow = true } }
        route.next = dest
        SetWaypoint(inst, dest.X, dest.Y, dest.map)
        if not quiet then
            ns:Print(("Route to %s: %d yards, about %s. (Flying isn't quicker%s.)"):format(dest.name,
                math.floor(Dist(X, Y, dest.X, dest.Y)), Duration(direct),
                #flights == 0 and " - no unlocked flight points known here" or ""))
        end
    end
end

-- keepWaypoint: the pin is already gone or isn't ours - leave the game's waypoint alone.
ClearRoute = function(why, keepWaypoint)
    if not route then return end
    route = nil
    if not keepWaypoint then ClearWaypoint() end
    lastSig = nil
    if why then ns:Print(why) end
end

-- New destination from a map spot.
local function RouteTo(mapID, x, y)
    local inst, X, Y = ToWorld(mapID, x, y)
    if not inst then ns:Print("Route: can't plan on this map."); return end
    local contMap = ContinentMap(mapID)
    local name
    if contMap and C_Map.GetMapInfoAtPosition then
        local cu, cv = ToMap(contMap, inst, X, Y)
        local info = cu and C_Map.GetMapInfoAtPosition(contMap, cu, cv)
        if info then name = info.name end
    end
    name = name or (C_Map.GetMapInfo(mapID) or {}).name or "there"
    route = { dest = { inst = inst, X = X, Y = Y, map = mapID, contMap = contMap, name = name } }
    Plan(false)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function Line()
    linesUsed = linesUsed + 1
    local l = linePool[linesUsed]
    if not l then
        l = routeLayer:CreateLine(nil, "OVERLAY")
        linePool[linesUsed] = l
    end
    l:Show()
    return l
end

local function DrawSegment(x1, y1, x2, y2, dashed, r, g, b)
    local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    if len < 1 then return end
    local function Piece(a, c)
        local l = Line()
        l:SetThickness(dashed and 3 or 4)
        l:SetColorTexture(r, g, b, 0.9)
        l:SetStartPoint("TOPLEFT", routeLayer, x1 + (x2 - x1) * a, -(y1 + (y2 - y1) * a))
        l:SetEndPoint("TOPLEFT", routeLayer, x1 + (x2 - x1) * c, -(y1 + (y2 - y1) * c))
    end
    if not dashed then Piece(0, 1); return end
    local step = (DASH + GAP) / len
    local dash = DASH / len
    local a = 0
    while a < 1 and linesUsed < 2000 do
        Piece(a, math.min(1, a + dash))
        a = a + step
    end
end

local function Draw(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (routeLayer and child) then return end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    local X, Y = PlayerWorld()
    local sig = ("%s:%d:%.5f:%.0f:%s:%s"):format(tostring(route), mapID, scale, W,
        X and math.floor(X / 4) or "-", Y and math.floor(Y / 4) or "-")
    if sig == lastSig and not force then return end
    lastSig = sig

    for i = 1, linesUsed do linePool[i]:Hide() end
    linesUsed = 0
    star:Hide()
    if clearButton and clearButton:IsShown() ~= (route ~= nil) then clearButton:SetShown(route ~= nil) end
    if not (route and On()) then return end

    routeLayer:SetScale(1 / scale)
    routeLayer:SetSize(W * scale, H * scale)
    local sx, sy = W * scale, H * scale
    local inst = route.dest.inst
    for _, leg in ipairs(route.legs or {}) do
        local from = leg.from
        if leg.follow and X then from = { X = X, Y = Y } end   -- first leg starts where you are now
        local u1, v1 = ToMap(mapID, inst, from.X, from.Y)
        local u2, v2 = ToMap(mapID, inst, leg.to.X, leg.to.Y)
        if u1 and u2 then
            if leg.kind == "fly" then
                DrawSegment(u1 * sx, v1 * sy, u2 * sx, v2 * sy, false, 0.35, 0.75, 1)
            else
                DrawSegment(u1 * sx, v1 * sy, u2 * sx, v2 * sy, true, 1, 0.85, 0.2)
            end
        end
    end
    local du, dv = ToMap(mapID, inst, route.dest.X, route.dest.Y)
    if du then
        star:ClearAllPoints()
        star:SetPoint("CENTER", routeLayer, "TOPLEFT", du * sx, -dv * sy)
        star:Show()
    end
end

---------------------------------------------------------------------------
-- Double-click on the map
---------------------------------------------------------------------------

local function OnMouseDown(sc, button)
    if button ~= "LeftButton" or not On() then return end
    local mapID = WorldMapFrame:GetMapID()
    local mx, my
    if sc.GetNormalizedCursorPosition then mx, my = sc:GetNormalizedCursorPosition() end
    local cx, cy = GetCursorPosition()
    local now = GetTime()
    local prev = lastDown
    lastDown = { t = now, x = cx, y = cy, mapID = mapID, mx = mx, my = my }
    if prev and now - prev.t <= DOUBLE_CLICK and math.abs(cx - prev.x) <= DOUBLE_PIXELS
        and math.abs(cy - prev.y) <= DOUBLE_PIXELS and prev.mx then
        lastDown = nil
        -- on the destination star: remove the route instead
        if route and star:IsVisible() then
            local sx, sy = star:GetCenter()
            local s = star:GetEffectiveScale()
            if sx and math.abs(sx * s - prev.x) <= STAR_PIXELS and math.abs(sy * s - prev.y) <= STAR_PIXELS then
                ClearRoute("Route removed.")
                return
            end
        end
        -- the FIRST click's spot: on a continent map that click may have opened the zone
        RouteTo(prev.mapID, prev.mx, prev.my)
    end
end

---------------------------------------------------------------------------
-- Options, commands, setup
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "mapRoute",
    type = "toggle",
    label = "Double-click the map to plan a route",
    tooltip = "Double-click a spot on the world map (double-click its star again to remove it): the map draws the quickest way there - walking (dashed) or via flight points you've unlocked (blue) - and the game's arrow points you to the next stop. It re-plans after you land and clears when you arrive. A Clear route button sits at the bottom-left of the map.\n\nWalking legs are straight lines: addons can't see the game's pathfinding.",
    default = true,
    onChange = function(v) if not v then ClearRoute() end; lastSig = nil end,
})

ns:RegisterCommand("route", "show the current map route, or /p13 route clear", function(text)
    if strtrim(text or ""):lower() == "clear" then ClearRoute("Route cleared."); return end
    if not route then ns:Print("No route. Double-click the world map to plan one."); return end
    Plan(false)
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_CONTROL_GAINED")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("USER_WAYPOINT_UPDATED")
events:SetScript("OnEvent", function(_, event)
    if event == "USER_WAYPOINT_UPDATED" then
        OnWaypointChanged()
    elseif event == "PLAYER_LOGIN" then
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        if not (sc and sc.Child and sc.GetCanvasScale) then return end
        routeLayer = CreateFrame("Frame", nil, sc.Child)
        routeLayer:SetPoint("TOPLEFT", sc.Child, "TOPLEFT")
        routeLayer:SetFrameLevel(sc.Child:GetFrameLevel() + 18)   -- under flight point icons
        star = routeLayer:CreateTexture(nil, "OVERLAY")
        star:SetSize(18, 18)
        star:SetTexture(STAR)
        star:Hide()
        sc:HookScript("OnMouseDown", OnMouseDown)

        clearButton = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
        clearButton:SetSize(90, 22)
        clearButton:SetText("Clear route")
        clearButton:SetFrameLevel(sc:GetFrameLevel() + 100)
        clearButton:SetScript("OnClick", function() ClearRoute() end)
        clearButton:Hide()
        ns:AddMapButton(clearButton, 25)

        -- While our route owns the game's waypoint, hide its map pin: the star marks the spot
        -- (and the pin would catch the double-click meant for the star). The arrow stays.
        local function HideGamePin()
            if not (route and ourPoint and WorldMapFrame.EnumeratePinsByTemplate) then return end
            for pin in WorldMapFrame:EnumeratePinsByTemplate("WaypointLocationPinTemplate") do
                if pin:IsShown() then pin:Hide() end
            end
        end

        local poll = CreateFrame("Frame", nil, WorldMapFrame)
        poll:SetScript("OnUpdate", function() HideGamePin(); Draw(false) end)
        ns.AddMapLayerRefresh(function() Draw(false) end)
        poll:SetScript("OnShow", function() Draw(true) end)
    elseif route then
        -- landed, or a new zone: plan again from here (quietly)
        C_Timer.After(1, function() if route then Plan(true) end end)
    end
end)

-- Once a second, map open or not: learn mount speed, notice landing / arrival.
local ticker = CreateFrame("Frame")
local since = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since < 1 then return end
    since = 0
    NoteSpeed()
    local onTaxi = UnitOnTaxi("player")
    if wasOnTaxi and not onTaxi and route then Plan(true) end
    wasOnTaxi = onTaxi
    if not route or onTaxi or route.other then return end
    local X, Y, inst = PlayerWorld()
    if not X or inst ~= route.dest.inst then return end
    if Dist(X, Y, route.dest.X, route.dest.Y) <= ARRIVE_YARDS then
        ClearRoute("Route: you've arrived.")
    end
end)

-- P13Tweaks feature: the lines drawn on the world map (MapDraw.lua: yours and your group's) also show on the
-- minimap. Each line's points are map positions; they're turned into world positions once (cached), then
-- every frame projected onto the minimap around you: north up, or turned by your facing when the minimap
-- rotates. A line is cut off at the minimap's round edge (frames aren't clipped by the minimap's mask).
-- Needs MapDraw.lua (ns.SheetDraw). World axes as everywhere in this addon: X = north, Y = west
-- (UnitPosition / C_Map.GetWorldPosFromMapPos); GetPlayerFacing() is 0 facing north, growing turning left.
local ADDON_NAME, ns = ...

local EDGE       = 0.97   -- lines are cut a little inside the minimap's border ring
local MAX_LINES  = 600

-- Width of the minimap in yards at each zoom level (the standard values, as HereBeDragons uses).
local SIZE = {
    outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
    indoor  = { [0] = 300, 240, 180, 120, 80, 50 },
}
ns.MINIMAP_YARDS = SIZE   -- (also used by FarmHeat.lua)

local layer, pool, used = nil, {}, 0
local dots, dotsUsed = {}, 0   -- round dots at the joints of thick lines (like on the world map)
local indoors = false
local checking = false
local lastSig

local function Enabled()
    return ns:Get("mapDrawMinimap") and ns.SheetDraw and ns.SheetDraw.enabled()
end

-- Is the minimap showing its outdoor or its indoor zoom scale? (IsIndoors() isn't reliable for this.) Set the
-- zoom one step and see which saved zoom setting followed - the trick HereBeDragons uses - then put it back.
local function DetectIndoors()
    if checking or not (Minimap and Minimap.GetZoom and Minimap.SetZoom) then return end
    checking = true
    local zoom = Minimap:GetZoom()
    local levels = Minimap.GetZoomLevels and Minimap:GetZoomLevels() or 6
    if GetCVar("minimapZoom") == GetCVar("minimapInsideZoom") then
        Minimap:SetZoom(zoom < (levels - 1) and zoom + 1 or zoom - 1)
    end
    local outdoorZoom = tonumber(GetCVar("minimapZoom"))
    indoors = outdoorZoom ~= nil and outdoorZoom ~= Minimap:GetZoom()
    ns.minimapIndoors = indoors   -- (also used by FarmHeat.lua)
    Minimap:SetZoom(zoom)
    checking = false
    lastSig = nil
end

local function GetLine(i)
    local l = pool[i]
    if not l then
        l = layer:CreateLine(nil, "OVERLAY")
        pool[i] = l
    end
    return l
end

-- A stroke's points as world positions { inst, X = {...}, Y = {...}, bounds }, converted once and cached.
local function WorldPoints(s)
    local c = s.p13mini
    if c and c.ref == s.pts and c.n == #s.pts then return c end
    c = { ref = s.pts, n = #s.pts, X = {}, Y = {} }
    s.p13mini = c
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return c end
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for i, p in ipairs(s.pts) do
        local inst, w = C_Map.GetWorldPosFromMapPos(s.map, CreateVector2D(p[1], p[2]))
        if not (inst and w) then c.bad = true break end
        local X, Y = w:GetXY()
        c.inst = inst
        c.X[i], c.Y[i] = X, Y
        if X < minX then minX = X end
        if X > maxX then maxX = X end
        if Y < minY then minY = Y end
        if Y > maxY then maxY = Y end
    end
    c.minX, c.maxX, c.minY, c.maxY = minX, maxX, minY, maxY
    return c
end

-- The part of the segment (x0,y0)-(x1,y1) inside the circle of radius R around 0,0, or nil.
local function ClipToCircle(x0, y0, x1, y1, R)
    local dx, dy = x1 - x0, y1 - y0
    local a = dx * dx + dy * dy
    if a < 1e-9 then return end
    local b = 2 * (x0 * dx + y0 * dy)
    local c = x0 * x0 + y0 * y0 - R * R
    local disc = b * b - 4 * a * c
    if disc <= 0 then return end
    local sq = math.sqrt(disc)
    local lo = math.max(0, (-b - sq) / (2 * a))
    local hi = math.min(1, (-b + sq) / (2 * a))
    if lo >= hi then return end
    return x0 + dx * lo, y0 + dy * lo, x0 + dx * hi, y0 + dy * hi
end

local function Hide()
    for i = 1, used do pool[i]:Hide() end
    for i = 1, dotsUsed do dots[i]:Hide() end
    used, dotsUsed = 0, 0
    lastSig = nil
end

local function Update()
    if not Enabled() or not Minimap:IsVisible() then
        if used > 0 or dotsUsed > 0 then Hide() end
        return
    end
    local pX, pY, _, pInst = UnitPosition("player")
    if pX == nil or (issecretvalue and (issecretvalue(pX) or issecretvalue(pY))) then
        if used > 0 or dotsUsed > 0 then Hide() end
        return
    end
    local rotating = GetCVar("rotateMinimap") == "1"
    local facing = 0
    if rotating then
        facing = GetPlayerFacing and GetPlayerFacing() or 0
        if issecretvalue and issecretvalue(facing) then facing = 0 end
    end
    local zoom = Minimap:GetZoom() or 0
    local table_ = indoors and SIZE.indoor or SIZE.outdoor
    local diameterYd = table_[zoom] or table_[#table_]
    local halfPx = Minimap:GetWidth() / 2
    -- (the time part: lines fade out over their last seconds, so redraw now and then even when you stand still)
    local sig = ("%.2f:%.2f:%.3f:%d:%s:%.1f:%d:%d"):format(pX, pY, facing, zoom, tostring(indoors), halfPx,
        ns.SheetDraw.version(), math.floor(GetTime() / 2))
    if sig == lastSig then return end
    lastSig = sig

    local k = halfPx / (diameterYd / 2)         -- px per yard
    local R = halfPx * EDGE
    local cosF, sinF = math.cos(facing), math.sin(facing)
    local reachYd = diameterYd / 2 * 1.05
    local strokes = ns.SheetDraw.strokes()
    local n, nd = 0, 0
    local dotFrom = ns.SheetDraw.dotFrom or 4
    for _, s in ipairs(strokes) do
        local w = WorldPoints(s)
        if w.inst == pInst and not w.bad and w.minX
            and w.maxX > pX - reachYd and w.minX < pX + reachYd and w.maxY > pY - reachYd and w.minY < pY + reachYd then
            local alpha = ns.SheetDraw.alpha(s)
            local col = s.color
            local th = ns.SheetDraw.thicknessOf(s)   -- the brush size it was drawn with (screen px, same as on the map)
            local px0, py0
            for i = 1, #w.X do
                -- world offset from you -> minimap pixels (x right = east, y up = north)
                local x, y = -(w.Y[i] - pY), w.X[i] - pX
                if rotating then x, y = x * cosF + y * sinF, -x * sinF + y * cosF end
                x, y = x * k, y * k
                if i > 1 and n < MAX_LINES then
                    local ax, ay, bx, by = ClipToCircle(px0, py0, x, y, R)
                    if ax then
                        n = n + 1
                        local l = GetLine(n)
                        l:SetThickness(th)
                        l:SetColorTexture(col[1], col[2], col[3], alpha)
                        l:SetStartPoint("CENTER", layer, ax, ay)
                        l:SetEndPoint("CENTER", layer, bx, by)
                        l:Show()
                    end
                end
                -- thick lines get a round dot at each joint (as on the world map), so the corners join up
                if th >= dotFrom and nd < MAX_LINES and x * x + y * y <= R * R then
                    nd = nd + 1
                    local d = dots[nd]
                    if not d then d = ns.SheetDraw.makeDot(layer); dots[nd] = d end
                    d:SetSize(th, th)
                    d:ClearAllPoints()
                    d:SetPoint("CENTER", layer, "CENTER", x, y)
                    d:SetColorTexture(col[1], col[2], col[3], alpha)
                    d:Show()
                end
                px0, py0 = x, y
            end
        end
    end
    for i = n + 1, used do pool[i]:Hide() end
    for i = nd + 1, dotsUsed do dots[i]:Hide() end
    used, dotsUsed = n, nd
end

ns:RegisterOption({
    key = "mapDrawMinimap",
    type = "toggle",
    label = "Show map drawings on the minimap",
    tooltip = "The lines drawn on the world map (yours and your group's) also show on the minimap, around you, cut off at its round edge, in the colour and brush size they were drawn with.",
    default = true,
    onChange = function() lastSig = nil end,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event)
    if event ~= "PLAYER_LOGIN" then DetectIndoors() return end
    if not (Minimap and ns.SheetDraw) then return end
    layer = CreateFrame("Frame", nil, Minimap)
    layer:SetAllPoints(Minimap)
    layer:SetFrameLevel(Minimap:GetFrameLevel() + 4)
    layer:SetScript("OnUpdate", Update)
    -- (not MINIMAP_UPDATE_ZOOM: DetectIndoors itself changes the zoom, which would fire it again, forever)
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do
        self:RegisterEvent(e)
    end
    hooksecurefunc(Minimap, "SetZoom", function() if not checking then lastSig = nil end end)
    DetectIndoors()
end)

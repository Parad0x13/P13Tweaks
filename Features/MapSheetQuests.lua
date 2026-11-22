-- P13Tweaks feature: where your quests need you, on the tile map.
-- For every quest you are tracking, the tile map shades the places the work is done (the spawn points of
-- what to kill / collect / use, from QuestieDB via ns.QuestObjectivePoints in QuestWhere.lua) with gold
-- translucent discs that run together into areas; once a quest's objectives are done, a gold "?" marks
-- where to hand it in. Needs QuestieDB. Drawn by a hook MapSheet.lua calls every frame (ns.SheetHooks).
local ADDON_NAME, ns = ...

local DONE_ICON = "Interface\\GossipFrame\\ActiveQuestIcon"   -- "?"
local DISC_TILES = 0.12     -- a disc is this many tiles across, but never less than DISC_MIN_PX on screen
local DISC_MIN_PX = 10
local REFRESH = 2           -- seconds between looks at the quest log

local layer
local discs, discsUsed = {}, 0
local icons, iconsUsed = {}, 0
local quests = {}           -- { id = , ready = } for the tracked quests
local questsAt, version = 0, 0
local tileCache = {}        -- "id:ready:world" -> { {tx, ty}... }
local lastSig

local function On() return ns:Get("mapSheetQuests") end

-- The quests being tracked: id and whether all their objectives are done.
local function IsReady(id)
    if C_QuestLog and C_QuestLog.ReadyForTurnIn then
        local ok, r = pcall(C_QuestLog.ReadyForTurnIn, id)
        if ok then return r and true or false end
    end
    if C_QuestLog and C_QuestLog.IsComplete then
        local ok, r = pcall(C_QuestLog.IsComplete, id)
        if ok then return r and true or false end
    end
    return false
end

local how = "?"   -- which way of reading the quest log worked (shown by /p13 sheetquests)
local function TrackedQuests()
    local out, seen = {}, {}
    local function Add(id, ready)
        if type(id) == "number" and id > 0 and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, ready = ready and true or false }
        end
    end
    -- newer clients: C_QuestLog
    if C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetQuestIDForQuestWatchIndex then
        how = "C_QuestLog watches"
        for i = 1, C_QuestLog.GetNumQuestWatches() or 0 do
            local id = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
            Add(id, IsReady(id))
        end
    end
    -- older clients: the global functions
    if #out == 0 and GetNumQuestWatches and GetQuestIndexForWatch and GetQuestLogTitle then
        how = "global watches"
        for i = 1, GetNumQuestWatches() or 0 do
            local index = GetQuestIndexForWatch(i)
            if index then
                local _, _, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(index)
                if not isHeader then Add(id, isComplete and isComplete > 0) end
            end
        end
    end
    -- nothing tracked (or no way to read it): fall back to the whole quest log
    if #out == 0 then
        if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
            how = "C_QuestLog whole log"
            for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
                local info = C_QuestLog.GetInfo(i)
                if info and not info.isHeader then Add(info.questID, IsReady(info.questID)) end
            end
        elseif GetNumQuestLogEntries and GetQuestLogTitle then
            how = "global whole log"
            for i = 1, GetNumQuestLogEntries() or 0 do
                local _, _, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(i)
                if not isHeader then Add(id, isComplete and isComplete > 0) end
            end
        end
    end
    return out
end

local function SameQuests(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i].id ~= b[i].id or a[i].ready ~= b[i].ready then return false end
    end
    return true
end

-- The quest's points as tile positions in the world being shown.
local function TilePoints(q, world)
    local key = q.id .. (q.ready and ":r:" or ":w:") .. tostring(world)
    local c = tileCache[key]
    if c then return c end
    local fn = q.ready and ns.QuestFinisherPoints or ns.QuestObjectivePoints
    local pts = fn and fn(q.id) or {}
    local out = {}
    for _, p in ipairs(pts) do
        if p.uiMap and p.x and p.y then
            local tx, ty = ns.SheetMapToTile(p.uiMap, p.x / 100, p.y / 100)
            if tx then out[#out + 1] = { tx, ty } end
        end
    end
    -- only keep an answer when QuestieDB had something to say (it may just not be loaded yet)
    if #pts > 0 then tileCache[key] = out end
    return out
end

-- The smallest convex shape around a set of points (monotone chain). Returns the corners in order, or
-- fewer than 3 points when they all lie on a line.
local function Hull(pts)
    local p = {}
    for i, q in ipairs(pts) do p[i] = q end
    table.sort(p, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
    if #p < 3 then return p end
    local function cross(o, a, b) return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1]) end
    local lower, upper = {}, {}
    for i = 1, #p do
        while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p[i]) <= 0 do lower[#lower] = nil end
        lower[#lower + 1] = p[i]
    end
    for i = #p, 1, -1 do
        while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p[i]) <= 0 do upper[#upper] = nil end
        upper[#upper + 1] = p[i]
    end
    lower[#lower] = nil
    upper[#upper] = nil
    for _, q in ipairs(upper) do lower[#lower + 1] = q end
    return lower
end

-- Spawn points that lie close together belong to one area: chain points within CLUSTER_TILES of each
-- other (single linkage), so a camp of creatures is one area and a far-off camp is another.
local CLUSTER_TILES = 0.35   -- about 190 yards
local PAD_TILES = 0.05       -- the outline sits this far outside the outermost points
local function Clusters(pts)
    local parent = {}
    for i = 1, #pts do parent[i] = i end
    local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
    local r2 = CLUSTER_TILES ^ 2
    for i = 1, #pts do
        for j = i + 1, #pts do
            if (pts[i][1] - pts[j][1]) ^ 2 + (pts[i][2] - pts[j][2]) ^ 2 <= r2 then parent[find(i)] = find(j) end
        end
    end
    local groups, order = {}, {}
    for i = 1, #pts do
        local r = find(i)
        if not groups[r] then groups[r] = {}; order[#order + 1] = r end
        table.insert(groups[r], pts[i])
    end
    local out = {}
    for _, r in ipairs(order) do out[#out + 1] = groups[r] end
    return out
end

-- Push each corner of a shape outward from its middle by PAD_TILES.
local function Pad(hull)
    local mx, my = 0, 0
    for _, p in ipairs(hull) do mx, my = mx + p[1], my + p[2] end
    mx, my = mx / #hull, my / #hull
    local out = {}
    for i, p in ipairs(hull) do
        local dx, dy = p[1] - mx, p[2] - my
        local d = math.sqrt(dx * dx + dy * dy)
        out[i] = d > 0 and { p[1] + dx / d * PAD_TILES, p[2] + dy / d * PAD_TILES } or { p[1], p[2] }
    end
    return out
end

-- Round off a polygon's corners (Chaikin's corner cutting, twice): each edge is replaced by two points a
-- quarter and three quarters along it, so the straight-edged outline becomes a soft blob like the game's own.
local function Smooth(poly)
    for _ = 1, 2 do
        local out, n = {}, #poly
        for i = 1, n do
            local a, b = poly[i], poly[i % n + 1]
            out[#out + 1] = { a[1] * 0.75 + b[1] * 0.25, a[2] * 0.75 + b[2] * 0.25 }
            out[#out + 1] = { a[1] * 0.25 + b[1] * 0.75, a[2] * 0.25 + b[2] * 0.75 }
        end
        poly = out
    end
    return poly
end

-- The areas a quest needs you in, as tile positions: a list of { outline = { {tx, ty}... } or nil, spots = { {tx, ty}... } }.
--  * a "go to this area" quest (QuestieDB triggerEnd): its points, joined up in the order they are stored;
--  * the spawn points of what to kill / collect / use: grouped into clusters, each wrapped in its outline.
-- A group of fewer than 3 points (or all in a line) has no outline: it is drawn as spots.
local shapeCache = {}
local function Shapes(q, world)
    local key = q.id .. ":" .. tostring(world)
    local c = shapeCache[key]
    if c then return c end
    local out = {}
    local raw = ns.QuestAreaPolys and ns.QuestAreaPolys(q.id) or {}
    for _, poly in ipairs(raw) do
        local pts = {}
        for _, p in ipairs(poly.pts) do
            local tx, ty = ns.SheetMapToTile(poly.uiMap, p[1] / 100, p[2] / 100)
            if tx then pts[#pts + 1] = { tx, ty } end
        end
        if #pts >= 3 then out[#out + 1] = { outline = Smooth(pts), spots = pts }
        elseif #pts > 0 then out[#out + 1] = { spots = pts } end
    end
    local spawns = ns.QuestObjectivePoints and ns.QuestObjectivePoints(q.id, true) or {}
    local tiles = {}
    for _, p in ipairs(spawns) do
        if p.uiMap and p.x and p.y then
            local tx, ty = ns.SheetMapToTile(p.uiMap, p.x / 100, p.y / 100)
            if tx then tiles[#tiles + 1] = { tx, ty } end
        end
    end
    for _, group in ipairs(Clusters(tiles)) do
        local hull = #group >= 3 and Hull(group) or nil
        if hull and #hull >= 3 then out[#out + 1] = { outline = Smooth(Pad(hull)), spots = group }
        else out[#out + 1] = { spots = group } end
    end
    if #raw > 0 or #spawns > 0 then shapeCache[key] = out end   -- (keep an answer only when QuestieDB had something to say)
    return out
end

-- Fill a polygon (screen points, y down) with horizontal strips: for each strip, find where the outline
-- crosses its middle, and fill between each pair of crossings. Strips are at least 3 px tall and there are
-- at most ~60 of them over the visible part, so the cost stays small however big the area is.
local fills, fillsUsed = {}, 0
local function FillPolygon(view, pts, w, h)
    local ymin, ymax = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[2] < ymin then ymin = p[2] end
        if p[2] > ymax then ymax = p[2] end
    end
    local top, bottom = math.max(ymin, -4), math.min(ymax, h + 4)
    if bottom <= top then return end
    local sh = math.max(3, (bottom - top) / 60)
    local n = #pts
    local y = ymin + math.floor((top - ymin) / sh) * sh
    while y < bottom do
        local yc = y + sh / 2
        local xs = {}
        for i = 1, n do
            local a, b = pts[i], pts[i % n + 1]
            if (a[2] <= yc and b[2] > yc) or (b[2] <= yc and a[2] > yc) then
                xs[#xs + 1] = a[1] + (yc - a[2]) / (b[2] - a[2]) * (b[1] - a[1])
            end
        end
        table.sort(xs)
        for i = 1, #xs - 1, 2 do
            local x1, x2 = math.max(xs[i], -4), math.min(xs[i + 1], w + 4)
            if x2 > x1 and fillsUsed < 600 then
                fillsUsed = fillsUsed + 1
                local t = fills[fillsUsed]
                if not t then t = layer:CreateTexture(nil, "ARTWORK"); fills[fillsUsed] = t end
                t:SetColorTexture(0.25, 0.30, 1, 0.38)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", view, "TOPLEFT", x1, -y)
                t:SetSize(x2 - x1, sh)
                t:Show()
            end
        end
        y = y + sh
    end
end

local outlines, outlinesUsed = {}, 0

---------------------------------------------------------------------------
-- The game's own quest areas (the blue shapes on the normal world map)
-- The game draws them with a "QuestPOIFrame": give it a map and a quest, and it draws that quest's area over
-- the frame, using the server's own area data (no QuestieDB needed). We make one per quest and zone it
-- is in, size it to that zone's rectangle on the sheet, and then only SCALE and MOVE it as you zoom and pan
-- (the shape is worked out once, not every frame).
---------------------------------------------------------------------------

local passes = 0             -- how many times the hook has run (so a draw can wait one frame)
local BLOB_W = 165           -- the area widget's frame is this many units wide (the size that worked in the test), then scaled up
local blobs = {}             -- "questID:uiMap" -> frame (false = could not be made)
local blobsShown = {}
local blobGen = 0            -- bumps when the quest log changes: shapes are drawn again
local nativeOk               -- nil = not tried yet, true / false once we know
local rectCache = {}         -- "uiMap:world" -> { left, top, w, h } in tiles

local function NativeOn() return ns:Get("mapSheetQuestsNative") and nativeOk ~= false end

local function ZoneRect(uiMap, world)
    local key = uiMap .. ":" .. tostring(world)
    local r = rectCache[key]
    if r ~= nil then return r or nil end
    local x0, y0 = ns.SheetMapToTile(uiMap, 0, 0)
    local x1, y1 = ns.SheetMapToTile(uiMap, 1, 1)
    if x0 and x1 and math.abs(x1 - x0) > 1e-6 and math.abs(y1 - y0) > 1e-6 then
        r = { left = math.min(x0, x1), top = math.min(y0, y1), w = math.abs(x1 - x0), h = math.abs(y1 - y0) }
    end
    rectCache[key] = r or false
    return r
end

-- The zones a quest has points in (from QuestieDB; the game's own data says which zone a quest is in only
-- for the one you're looking at).
local function QuestMaps(q)
    local maps, seen = {}, {}
    local function Add(m) if type(m) == "number" and m > 0 and not seen[m] and #maps < 4 then seen[m] = true; maps[#maps + 1] = m end end
    if GetQuestUiMapID then local ok, m = pcall(GetQuestUiMapID, q.id); if ok then Add(m) end end
    if C_QuestLog and C_QuestLog.GetQuestUiMapID then local ok, m = pcall(C_QuestLog.GetQuestUiMapID, q.id); if ok then Add(m) end end
    for _, p in ipairs(ns.QuestObjectivePoints and ns.QuestObjectivePoints(q.id) or {}) do Add(p.uiMap) end
    return maps
end

local function Blob(qid, uiMap)
    local key = qid .. ":" .. uiMap
    local f = blobs[key]
    if f ~= nil then return f or nil end
    if nativeOk == false then return end
    -- Like the game's own map: the area widget sits inside a holder frame that is scaled and placed, and
    -- fills it (the widget doesn't follow its own scale, but does follow its parents').
    local holder = CreateFrame("Frame", nil, layer)
    holder:SetFrameLevel(layer:GetFrameLevel() + 1)
    local ok, frame = pcall(CreateFrame, "QuestPOIFrame", nil, holder)
    -- (this client names the map function SetMapID; newer ones SetUiMapID)
    if not (ok and frame and frame.DrawBlob and (frame.SetMapID or frame.SetUiMapID)) then
        nativeOk, blobs[key] = false, false
        if ok and frame then frame:Hide() end
        holder:Hide()
        return
    end
    nativeOk = true
    frame.qid, frame.uiMap, frame.holder = qid, uiMap, holder
    frame:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)   -- (sized explicitly in PlaceBlob: anchored sizing did not work)
    local function Try(name, ...) if frame[name] then pcall(frame[name], frame, ...) end end
    Try("SetFillTexture", "Interface\\WorldMap\\UI-QuestBlob-Inside")
    Try("SetBorderTexture", "Interface\\WorldMap\\UI-QuestBlob-Outside")
    Try("SetFillAlpha", 128)
    Try("SetBorderAlpha", 192)
    Try("SetBorderScalar", 1.0)
    Try("EnableMerging", true)
    Try("EnableSmoothing", true)
    Try("SetMouseClickEnabled", false)
    Try("SetMouseMotionEnabled", false)
    blobs[key] = frame
    return frame
end

-- Put the quest's area for zone `uiMap` on the sheet; returns true if a frame was placed.
local function PlaceBlob(view, q, uiMap, cx, cy, zoom, w, h, world)
    local r = ZoneRect(uiMap, world)
    if not r then return false end
    local sx, sy = (r.left - cx) * zoom + w / 2, (r.top - cy) * zoom + h / 2
    if sx > w or sy > h or sx + r.w * zoom < 0 or sy + r.h * zoom < 0 then return true end   -- off screen
    local f = Blob(q.id, uiMap)
    if not f then return false end
    -- What the blob tests showed: the widget draws correctly in a SMALL frame with an explicit size (about 165 x 110
    -- units) that sits inside a scaled parent - in big frames (330+ wide) its shape came out tiny and far away. So
    -- the frame stays a small fixed size (BLOB_W wide, the zone's shape), is drawn ONCE, and the holder around it is
    -- scaled and moved to cover the zone on screen. Zooming only changes the holder's scale: no redrawing.
    local bw = BLOB_W
    local bh = BLOB_W * r.h / r.w
    local s = r.w * zoom / BLOB_W
    f.dbg = ("map %d zone rect (tiles) left %.2f top %.2f w %.2f h %.2f | screen sx %.0f sy %.0f | zoom %.2f scale %.3f | frame %.0fx%.0f | view %dx%d | view centre tile %.2f,%.2f"):format(
        uiMap, r.left, r.top, r.w, r.h, sx, sy, zoom, s, bw, bh, w, h, cx, cy)
    local holder = f.holder
    holder:SetScale(s)
    holder:ClearAllPoints()
    holder:SetPoint("TOPLEFT", view, "TOPLEFT", sx / s, -sy / s)
    holder:Show()
    f:Show()
    if math.abs((f.bw or 0) - bw) > 0.5 or math.abs((f.bh or 0) - bh) > 0.5 or f.gen ~= blobGen then
        holder:SetSize(bw, bh)
        f:SetSize(bw, bh)
        pcall(f.SetMapID or f.SetUiMapID, f, uiMap)
        f.bw, f.bh, f.gen = bw, bh, blobGen
        f.drawAt = GetTime() + 0.4       -- the test drew half a second after sizing; do the same
        f.needsDraw = true
    end
    if f.needsDraw then
        if GetTime() >= f.drawAt then
            pcall(f.DrawBlob, f, q.id, true)
            f.needsDraw = false
            f.drawn = { uiMap = uiMap, w = bw, h = bh }
        else
            lastSig = nil                -- come back next frame
        end
    end
    blobsShown[#blobsShown + 1] = holder   -- (hiding the holder hides the area with it)
    return true
end

local function MakeDisc(parent)
    local t = parent:CreateTexture(nil, "ARTWORK")
    if parent.CreateMaskTexture and t.AddMaskTexture then
        local mask = parent:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(t)
        t:AddMaskTexture(mask)
    end
    return t
end

local function Hook(view, cx, cy, zoom, w, h, world)
    passes = passes + 1
    if not layer then
        layer = CreateFrame("Frame", nil, view)
        layer:SetAllPoints(view)
        layer:SetFrameLevel(view:GetFrameLevel() + 3)   -- above the tiles, below the drawn lines (+5)
    end

    -- look at the quest log now and then
    if GetTime() - questsAt > REFRESH then
        questsAt = GetTime()
        local now = On() and TrackedQuests() or {}
        if not SameQuests(now, quests) then quests = now; version = version + 1 end
    end

    local sig = ("%d:%.4f:%.4f:%.3f:%d:%d:%s:%s"):format(version, cx, cy, zoom, w or 0, h or 0, tostring(world), tostring(On()))
    if sig == lastSig then return end
    lastSig = sig

    for i = 1, discsUsed do discs[i]:Hide() end
    for i = 1, iconsUsed do icons[i]:Hide() end
    for i = 1, fillsUsed do fills[i]:Hide() end
    for i = 1, outlinesUsed do outlines[i]:Hide() end
    discsUsed, iconsUsed, fillsUsed, outlinesUsed = 0, 0, 0, 0
    for i = #blobsShown, 1, -1 do blobsShown[i]:Hide(); blobsShown[i] = nil end
    if not (On() and world and w and w > 0) then return end

    local size = math.max(DISC_MIN_PX, DISC_TILES * zoom)
    -- quests still being worked on: the game's own area for the quest if we can get it; otherwise (or if the
    -- game draws nothing for a zone we know) our own: an outline around the spawn points with its inside filled
    for _, q in ipairs(quests) do
        local native = false
        if not q.ready and NativeOn() then
            for _, uiMap in ipairs(QuestMaps(q)) do
                if PlaceBlob(view, q, uiMap, cx, cy, zoom, w, h, world) then native = true end
            end
        end
        if not q.ready and not native then
            for _, shape in ipairs(Shapes(q, world)) do
                if shape.outline then
                    local spts = {}
                    for i, p in ipairs(shape.outline) do spts[i] = { (p[1] - cx) * zoom + w / 2, (p[2] - cy) * zoom + h / 2 } end
                    FillPolygon(view, spts, w, h)
                    for i = 1, #spts do
                        if outlinesUsed >= 400 then break end
                        outlinesUsed = outlinesUsed + 1
                        local l = outlines[outlinesUsed]
                        if not l then l = layer:CreateLine(nil, "OVERLAY"); outlines[outlinesUsed] = l end
                        local a, b = spts[i], spts[i % #spts + 1]
                        l:SetThickness(2)
                        l:SetColorTexture(0.5, 0.6, 1, 0.95)
                        l:SetStartPoint("TOPLEFT", view, a[1], -a[2])
                        l:SetEndPoint("TOPLEFT", view, b[1], -b[2])
                        l:Show()
                    end
                else
                    for _, p in ipairs(shape.spots) do
                        local x, y = (p[1] - cx) * zoom + w / 2, (p[2] - cy) * zoom + h / 2
                        if discsUsed < 1500 and x > -size and x < w + size and y > -size and y < h + size then
                            discsUsed = discsUsed + 1
                            local d = discs[discsUsed]
                            if not d then d = MakeDisc(layer); discs[discsUsed] = d end
                            d:SetColorTexture(0.25, 0.30, 1, 0.38)
                            d:SetSize(size, size)
                            d:ClearAllPoints()
                            d:SetPoint("CENTER", view, "TOPLEFT", x, -y)
                            d:Show()
                        end
                    end
                end
            end
        end
    end
    -- quests ready to hand in: a "?" at the hand-in spot
    for _, q in ipairs(quests) do
        for _, p in ipairs(q.ready and TilePoints(q, world) or {}) do
            local x, y = (p[1] - cx) * zoom + w / 2, (p[2] - cy) * zoom + h / 2
            if x > -size and x < w + size and y > -size and y < h + size then   -- only what is in view
                if q.ready then
                    iconsUsed = iconsUsed + 1
                    local ic = icons[iconsUsed]
                    if not ic then
                        ic = layer:CreateTexture(nil, "OVERLAY")
                        ic:SetTexture(DONE_ICON)
                        ic:SetSize(24, 24)
                        icons[iconsUsed] = ic
                    end
                    ic:ClearAllPoints()
                    ic:SetPoint("CENTER", view, "TOPLEFT", x, -y)
                    ic:Show()
                elseif discsUsed < 1500 then
                    discsUsed = discsUsed + 1
                    local d = discs[discsUsed]
                    if not d then d = MakeDisc(layer); discs[discsUsed] = d end
                    d:SetColorTexture(0.25, 0.30, 1, 0.38)   -- overlapping discs run together into an area
                    d:SetSize(size, size)
                    d:ClearAllPoints()
                    d:SetPoint("CENTER", view, "TOPLEFT", x, -y)
                    d:Show()
                end
            end
        end
    end
end

ns.SheetHooks[#ns.SheetHooks + 1] = Hook

-- /p13 sheetquests: says what the quest layer sees (for when nothing shows)
ns:RegisterCommand("sheetquests", "tile map quest areas: what was found (debug; saved to the SavedVariables file on /reload)", function()
    -- chat can't be copied, so the lines are also kept in P13TweaksDB.sheetQuestsLog (written when you /reload or log out)
    local log = {}
    P13TweaksDB.sheetQuestsLog = log
    local function Say(text) ns:Print(text); log[#log + 1] = text end
    questsAt = 0
    local now = TrackedQuests()
    Say(("quest areas: option %s | quest log read by: %s | %d quests | QuestieDB %s | tile map open %s"):format(
        On() and "on" or "OFF", how, #now, _G.LibQuestieDB and "found" or "NOT FOUND",
        (_G.P13SheetFrame and _G.P13SheetFrame:IsShown()) and "yes" or "no"))
    -- why the game's widget can't be made: try it here and report exactly what happens
    do
        local ok, frame = pcall(CreateFrame, "QuestPOIFrame", nil, UIParent)
        if not ok then
            Say("  CreateFrame(\"QuestPOIFrame\") error: " .. tostring(frame))
        elseif not frame then
            Say("  CreateFrame(\"QuestPOIFrame\") returned nothing")
        else
            Say("  CreateFrame(\"QuestPOIFrame\") made a " .. tostring(frame:GetObjectType()) .. "; DrawBlob "
                .. tostring(frame.DrawBlob ~= nil) .. ", SetUiMapID " .. tostring(frame.SetUiMapID ~= nil))
            frame:Hide()
        end
        -- the game's own pin on the normal world map: what is it, and what can it do?
        local found
        if WorldMapFrame and WorldMapFrame.EnumeratePinsByTemplate then
            for _, tmpl in ipairs({ "QuestBlobPinTemplate", "QuestBlobPin" }) do
                for pin in WorldMapFrame:EnumeratePinsByTemplate(tmpl) do
                    found = found or { tmpl = tmpl, pin = pin }
                end
            end
        end
        if found then
            local names = {}
            local mt = getmetatable(found.pin)
            local idx = mt and type(mt.__index) == "table" and mt.__index
            for k, v in pairs(idx or {}) do if type(v) == "function" and (type(k) == "string") and (k:find("Blob") or k:find("Fill") or k:find("Border") or k:find("Map") or k:find("Merg") or k:find("Smooth") or k:find("Spline")) then names[#names + 1] = k end end
            table.sort(names)
            Say(("  the game's own pin %s is a %s: %s"):format(found.tmpl, tostring(found.pin:GetObjectType()), table.concat(names, ", ")))
        else
            Say("  no QuestBlobPinTemplate pin found on the normal world map (open it once, then try again)")
        end
        -- which widget types and pin templates exist at all
        local t = {}
        for _, name in ipairs({ "QuestPOIFrame", "ScenarioPOIFrame", "QuestBlobPinTemplate", "QuestBlobPinMixin", "QuestPOI_GetButton", "QuestPOI_DisplayButton", "QuestMapFrame_UpdateAll" }) do
            t[#t + 1] = name .. "=" .. tostring(_G[name] ~= nil)
        end
        Say("  globals: " .. table.concat(t, ", "))
    end
    local nb = 0
    for _, f in pairs(blobs) do if f then nb = nb + 1 end end
    Say(("game's own areas: option %s | QuestPOIFrame %s | %d area frames made, %d shown now"):format(
        ns:Get("mapSheetQuestsNative") and "on" or "off",
        nativeOk == nil and "not tried yet (open the tile map first)" or (nativeOk and "works" or "COULD NOT BE CREATED"), nb, #blobsShown))
    -- where each of the game's area frames is (screen units), and where its zone should be on the sheet
    for key, f in pairs(blobs) do
        if f then
            Say("     placed with: " .. tostring(f.dbg))
            Say(("  area frame %s: shown %s | left %s top %s width %s height %s | scale %.4f effective %.4f | drawn %s"):format(
                key, tostring(f:IsShown()), tostring(f:GetLeft() and math.floor(f:GetLeft())), tostring(f:GetTop() and math.floor(f:GetTop())),
                tostring(f:GetWidth() and math.floor(f:GetWidth())), tostring(f:GetHeight() and math.floor(f:GetHeight())),
                f:GetScale(), f:GetEffectiveScale(),
                f.drawn and ("map " .. tostring(f.drawn.uiMap)) or "no"))
        end
    end
    for _, q in ipairs(now) do
        local pts = (q.ready and ns.QuestFinisherPoints or ns.QuestObjectivePoints)
        pts = pts and pts(q.id) or {}
        local onWorld = 0
        for _, p in ipairs(pts) do
            if p.uiMap and ns.SheetMapToTile and ns.SheetMapToTile(p.uiMap, p.x / 100, p.y / 100) then onWorld = onWorld + 1 end
        end
        local polys = ns.QuestAreaPolys and ns.QuestAreaPolys(q.id) or {}
        local sizes = {}
        for _, poly in ipairs(polys) do sizes[#sizes + 1] = #poly.pts end
        local lib = _G.LibQuestieDB
        local name = lib and lib.Quest and lib.Quest.Get and select(2, pcall(lib.Quest.Get, q.id, "name"))
        Say(("  quest %d \"%s\"%s: %d points from QuestieDB, %d on the world shown; area outlines: %s"):format(
            q.id, tostring(name), q.ready and " (ready)" or "", #pts, onWorld,
            #polys == 0 and "none" or (#polys .. " (points: " .. table.concat(sizes, ", ") .. ")")))
        -- the raw records, to see where an area is really stored
        if lib and lib.Quest and lib.Quest.Get then
            local function Count(t) local n = 0 if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end return n end
            local function Raw(field)
                local ok, v = pcall(lib.Quest.Get, q.id, field)
                return ok and v or nil
            end
            local te, ex, ob = Raw("triggerEnd"), Raw("extraObjectives"), Raw("objectives")
            local zones, tp = 0, 0
            if type(te) == "table" and type(te[2]) == "table" then
                for _, p in pairs(te[2]) do zones = zones + 1; tp = tp + Count(p) end
            end
            Say(("     triggerEnd: %s%s | extraObjectives: %d | objectives: kill %d, object %d, item %d, other %d"):format(
                type(te) == "table" and ("\"" .. tostring(te[1]) .. "\", " .. zones .. " zones, " .. tp .. " points") or "none",
                "", Count(ex), type(ob) == "table" and Count(ob[1]) or 0, type(ob) == "table" and Count(ob[2]) or 0,
                type(ob) == "table" and Count(ob[3]) or 0, type(ob) == "table" and Count(ob[5]) or 0))
            if type(ex) == "table" then
                for i, e in pairs(ex) do
                    local zc, pc = 0, 0
                    if type(e) == "table" and type(e[1]) == "table" then
                        for _, p in pairs(e[1]) do zc = zc + 1; pc = pc + Count(p) end
                    end
                    Say(("     extraObjective %s: \"%s\", %d zones, %d points"):format(tostring(i), tostring(type(e) == "table" and e[3]), zc, pc))
                end
            end
        end
    end
    lastSig = nil
end)

ns:RegisterOption({
    key = "mapSheetQuests",
    type = "toggle",
    label = "Show my tracked quests' areas on the tile map",
    tooltip = "Shades the places where the quests you are tracking need you (where to kill, collect or use things) on the tile map, and puts a gold ? where a finished quest is handed in. Needs QuestieDB.",
    default = true,
    onChange = function() lastSig = nil end,
})

ns:RegisterOption({
    key = "mapSheetQuestsNative",
    type = "toggle",
    label = "Tile map quest areas: use the game's own shapes (experimental)",
    tooltip = "Asks the game to draw its own quest highlight (the blue shape the normal world map shows) on the tile map. Still being worked on: it may be in the wrong place. Untick it to use our own blue shapes, made from the quest's spawn points (QuestieDB), instead.",
    default = true,
    onChange = function() lastSig = nil end,
})

-- /p13 blobtest [questID] [mapID]: draws the game's area for one quest inside plain frames in the middle of the
-- screen, each with an outline and a red dot where the shape SHOULD be (the middle of the quest's spawn points
-- on that map), so a screenshot shows exactly how the game's widget places its shape inside a frame.
--   left frame:  480x320, drawn at scale 1
--   right frame: 240x160 inside a parent scaled x2 (also 480x320 on screen) - shows whether scaling is followed
local testFrames
ns:RegisterCommand("blobtest", "show where the game's quest-area widget puts its shape (debug; take a screenshot)", function(arg)
    if testFrames then
        for _, f in ipairs(testFrames) do f:Hide() end
        testFrames = nil
        ns:Print("blob test hidden.")
        return
    end
    local qid, uiMap = (arg or ""):match("(%d+)%s*(%d*)")
    qid, uiMap = tonumber(qid) or 872, tonumber(uiMap)
    -- the map: the one given, else the first zone QuestieDB has points for
    local pts = ns.QuestObjectivePoints and ns.QuestObjectivePoints(qid, true) or {}
    uiMap = uiMap or (pts[1] and pts[1].uiMap) or 1413
    -- where the shape should be: the middle of the spawn points on that map (0-1 across the map)
    local sx, sy, n = 0, 0, 0
    for _, p in ipairs(pts) do
        if p.uiMap == uiMap then sx, sy, n = sx + p.x / 100, sy + p.y / 100, n + 1 end
    end
    local ex, ey = n > 0 and sx / n or 0.5, n > 0 and sy / n or 0.5
    testFrames = {}
    local function Box(parent, w, h, x, y, label)
        local box = CreateFrame("Frame", nil, parent)
        box:SetFrameStrata("TOOLTIP")
        box:SetSize(w, h)
        box:SetPoint("CENTER", UIParent, "CENTER", x, y)
        local bg = box:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.6)
        for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", 2, 0 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 2, 0 },
                              { "TOPLEFT", "BOTTOMLEFT", 0, 2 }, { "TOPRIGHT", "BOTTOMRIGHT", 0, 2 } }) do
            local t = box:CreateTexture(nil, "BORDER")
            t:SetColorTexture(1, 1, 1, 1)
            t:SetPoint(e[1]); t:SetPoint(e[2])
            if e[3] > 0 then t:SetHeight(2) else t:SetWidth(2) end
        end
        local text = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("BOTTOM", box, "TOP", 0, 4)
        text:SetText(label)
        return box
    end
    local function Blob(box, w, h)
        local ok, f = pcall(CreateFrame, "QuestPOIFrame", nil, box)
        if not (ok and f) then ns:Print("could not create a QuestPOIFrame: " .. tostring(f)) return end
        f:SetAllPoints(box)
        f:SetFrameLevel(box:GetFrameLevel() + 2)
        local function Try(name, ...) if f[name] then pcall(f[name], f, ...) end end
        Try("SetFillTexture", "Interface\\WorldMap\\UI-QuestBlob-Inside")
        Try("SetBorderTexture", "Interface\\WorldMap\\UI-QuestBlob-Outside")
        Try("SetFillAlpha", 128)
        Try("SetBorderAlpha", 192)
        Try("SetBorderScalar", 1.0)
        pcall(f.SetMapID or f.SetUiMapID, f, uiMap)
        pcall(f.DrawBlob, f, qid, true)
        -- the red dot: where the shape should be
        local dot = box:CreateTexture(nil, "OVERLAY")
        dot:SetSize(8, 8)
        dot:SetColorTexture(1, 0, 0, 1)
        dot:SetPoint("CENTER", box, "TOPLEFT", ex * w, -ey * h)
        return f
    end
    local a = Box(UIParent, 480, 320, -270, 0, ("A: 480x320, scale 1 (quest %d, map %d)"):format(qid, uiMap))
    testFrames[#testFrames + 1] = a
    Blob(a, 480, 320)
    local holder = CreateFrame("Frame", nil, UIParent)
    holder:SetScale(2)
    holder:SetSize(240, 160)
    holder:SetPoint("CENTER", UIParent, "CENTER", 270 / 2, 0)
    testFrames[#testFrames + 1] = holder
    local b = Box(holder, 240, 160, 0, 0, "")
    b:ClearAllPoints()
    b:SetAllPoints(holder)
    b:SetFrameStrata("TOOLTIP")
    Blob(b, 240, 160)
    local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOM", holder, "TOP", 0, 4)
    label:SetText("B: 240x160 inside a parent scaled x2")
    ns:Print(("blob test: quest %d on map %d; red dot = middle of its spawn points (%.2f, %.2f from %d points). Take a screenshot, then /p13 blobtest again to hide."):format(
        qid, uiMap, ex, ey, n))
end)

-- /p13 blobtest2 [questID] [mapID]: four ways of sizing / timing / scaling the game's quest-area widget side by side
-- (the first test showed the shape drawn tiny and far away from its frame). Each box has an outline and a red dot
-- where the shape should be. Also saves the frame sizes the game saw into P13TweaksDB.blobTestLog.
--   A: the widget has an explicit size and one anchor; the shape is drawn straight away
--   B: same, but the shape is drawn half a second later (after the frame has been laid out)
--   C: like B, inside a parent scaled x2 (half-size frame)
--   D: like B, but sized by two anchors (SetAllPoints) instead of an explicit size
local test2
ns:RegisterCommand("blobtest2", "four variants of the game's quest-area widget (debug; take a screenshot)", function(arg)
    if test2 then
        for _, f in ipairs(test2) do f:Hide() end
        test2 = nil
        ns:Print("blob test 2 hidden.")
        return
    end
    local qid, uiMap = (arg or ""):match("(%d+)%s*(%d*)")
    qid, uiMap = tonumber(qid) or 872, tonumber(uiMap)
    local pts = ns.QuestObjectivePoints and ns.QuestObjectivePoints(qid, true) or {}
    uiMap = uiMap or (pts[1] and pts[1].uiMap) or 1413
    local sx, sy, n = 0, 0, 0
    for _, p in ipairs(pts) do
        if p.uiMap == uiMap then sx, sy, n = sx + p.x / 100, sy + p.y / 100, n + 1 end
    end
    local ex, ey = n > 0 and sx / n or 0.5, n > 0 and sy / n or 0.5
    P13TweaksDB.blobTestLog = {}
    local function Log(text) P13TweaksDB.blobTestLog[#P13TweaksDB.blobTestLog + 1] = text end
    test2 = {}
    local W, H = 330, 220

    -- a box with an outline and a red dot; `scale` is the parent's scale (the box is W/scale x H/scale in it)
    local function Box(label, x, y, scale)
        local holder = CreateFrame("Frame", nil, UIParent)
        holder:SetFrameStrata("TOOLTIP")
        holder:SetScale(scale)
        holder:SetSize(W / scale, H / scale)
        holder:SetPoint("CENTER", UIParent, "CENTER", x / scale, y / scale)
        test2[#test2 + 1] = holder
        local bg = holder:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.55)
        for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                              { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
            local t = holder:CreateTexture(nil, "BORDER")
            t:SetColorTexture(1, 1, 1, 1)
            t:SetPoint(e[1]); t:SetPoint(e[2])
            if e[3] then t:SetHeight(2) else t:SetWidth(2) end
        end
        local text = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("BOTTOM", holder, "TOP", 0, 3)
        text:SetText(label)
        local dot = holder:CreateTexture(nil, "OVERLAY")
        dot:SetSize(8, 8)
        dot:SetColorTexture(1, 0, 0, 1)
        dot:SetPoint("CENTER", holder, "TOPLEFT", ex * W / scale, -ey * H / scale)
        return holder
    end

    local function Make(holder, name, explicit, later)
        local ok, f = pcall(CreateFrame, "QuestPOIFrame", nil, holder)
        if not (ok and f) then Log(name .. ": could not create: " .. tostring(f)) return end
        f:SetFrameLevel(holder:GetFrameLevel() + 2)
        if explicit then
            f:SetSize(holder:GetWidth(), holder:GetHeight())
            f:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        else
            f:SetAllPoints(holder)
        end
        local function Try(m, ...) if f[m] then pcall(f[m], f, ...) end end
        Try("SetFillTexture", "Interface\\WorldMap\\UI-QuestBlob-Inside")
        Try("SetBorderTexture", "Interface\\WorldMap\\UI-QuestBlob-Outside")
        Try("SetFillAlpha", 128)
        Try("SetBorderAlpha", 192)
        Try("SetBorderScalar", 1.0)
        local function Draw()
            pcall(f.SetMapID or f.SetUiMapID, f, uiMap)
            pcall(f.DrawBlob, f, qid, true)
            Log(("%s: drew at size %s x %s, scale %s, effective %s, left %s top %s"):format(name,
                tostring(f:GetWidth()), tostring(f:GetHeight()), tostring(f:GetScale()), tostring(f:GetEffectiveScale()),
                tostring(f:GetLeft()), tostring(f:GetTop())))
        end
        if later then C_Timer.After(0.5, Draw) else Draw() end
    end

    Make(Box("A: explicit size, drawn at once", -175, 130, 1), "A", true, false)
    Make(Box("B: explicit size, drawn 0.5s later", 175, 130, 1), "B", true, true)
    Make(Box("C: in a parent scaled x2, drawn later", -175, -130, 2), "C", true, true)
    Make(Box("D: sized by anchors, drawn later", 175, -130, 1), "D", false, true)
    ns:Print(("blob test 2: quest %d on map %d; red dot = middle of its spawn points. Wait a second, take a screenshot, then /p13 blobtest2 again to hide, then /reload."):format(qid, uiMap))
end)

-- /p13 blobtest3 [questID] [mapID]: the area widget in four boxes that are all the same size on screen, but whose
-- parent frames have different scales (so the frame inside is smaller the higher the scale). In the last test the
-- only box that drew its shape properly was the one with the highest scale: is that what matters?
local test3
ns:RegisterCommand("blobtest3", "the quest-area widget at four parent scales (debug; take a screenshot)", function(arg)
    if test3 then
        for _, f in ipairs(test3) do f:Hide() end
        test3 = nil
        ns:Print("blob test 3 hidden.")
        return
    end
    local qid, uiMap = (arg or ""):match("(%d+)%s*(%d*)")
    qid, uiMap = tonumber(qid) or 872, tonumber(uiMap)
    local pts = ns.QuestObjectivePoints and ns.QuestObjectivePoints(qid, true) or {}
    uiMap = uiMap or (pts[1] and pts[1].uiMap) or 1413
    local sx, sy, n = 0, 0, 0
    for _, p in ipairs(pts) do
        if p.uiMap == uiMap then sx, sy, n = sx + p.x / 100, sy + p.y / 100, n + 1 end
    end
    local ex, ey = n > 0 and sx / n or 0.5, n > 0 and sy / n or 0.5
    P13TweaksDB.blobTestLog = {}
    test3 = {}
    local W, H = 330, 220
    local layout = { { 0.5, -175, 130 }, { 1, 175, 130 }, { 1.5, -175, -130 }, { 3, 175, -130 } }
    for _, spec in ipairs(layout) do
        local scale, x, y = spec[1], spec[2], spec[3]
        local holder = CreateFrame("Frame", nil, UIParent)
        holder:SetFrameStrata("TOOLTIP")
        holder:SetScale(scale)
        holder:SetSize(W / scale, H / scale)
        holder:SetPoint("CENTER", UIParent, "CENTER", x / scale, y / scale)
        test3[#test3 + 1] = holder
        local bg = holder:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.55)
        for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                              { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
            local t = holder:CreateTexture(nil, "BORDER")
            t:SetColorTexture(1, 1, 1, 1)
            t:SetPoint(e[1]); t:SetPoint(e[2])
            if e[3] then t:SetHeight(2 / scale) else t:SetWidth(2 / scale) end
        end
        local text = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("BOTTOM", holder, "TOP", 0, 3 / scale)
        text:SetText(("scale %s (frame %dx%d)"):format(tostring(scale), W / scale, H / scale))
        text:SetScale(1 / scale)
        local dot = holder:CreateTexture(nil, "OVERLAY")
        dot:SetSize(8 / scale, 8 / scale)
        dot:SetColorTexture(1, 0, 0, 1)
        dot:SetPoint("CENTER", holder, "TOPLEFT", ex * W / scale, -ey * H / scale)
        local ok, f = pcall(CreateFrame, "QuestPOIFrame", nil, holder)
        if ok and f then
            f:SetFrameLevel(holder:GetFrameLevel() + 2)
            f:SetSize(W / scale, H / scale)
            f:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
            local function Try(m, ...) if f[m] then pcall(f[m], f, ...) end end
            Try("SetFillTexture", "Interface\\WorldMap\\UI-QuestBlob-Inside")
            Try("SetBorderTexture", "Interface\\WorldMap\\UI-QuestBlob-Outside")
            Try("SetFillAlpha", 128)
            Try("SetBorderAlpha", 192)
            Try("SetBorderScalar", 1.0)
            C_Timer.After(0.5, function()
                pcall(f.SetMapID or f.SetUiMapID, f, uiMap)
                pcall(f.DrawBlob, f, qid, true)
                P13TweaksDB.blobTestLog[#P13TweaksDB.blobTestLog + 1] = ("scale %s: size %.0fx%.0f effective %.3f"):format(
                    tostring(scale), f:GetWidth(), f:GetHeight(), f:GetEffectiveScale())
            end)
        end
    end
    ns:Print(("blob test 3: quest %d on map %d. Wait a second, take a screenshot, then /p13 blobtest3 again to hide."):format(qid, uiMap))
end)

-- The game's own shapes turned out to land in the wrong place on the tile map, so that option is now off by
-- default. Saved settings already hold the old default ("on"): switch it off once (it can be ticked again).
local migrate = CreateFrame("Frame")
migrate:RegisterEvent("PLAYER_LOGIN")
migrate:SetScript("OnEvent", function()
    if not P13TweaksDB.nativeQuestAreasV3 then   -- (back on: being reworked, see PlaceBlob)
        P13TweaksDB.nativeQuestAreasV3 = true
        P13TweaksDB.mapSheetQuestsNative = true
    end
end)

-- the quest log changes when you accept, finish or untrack a quest: look again soon
local events = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED" }) do pcall(events.RegisterEvent, events, e) end   -- (not every client has both)
events:SetScript("OnEvent", function()
    questsAt = 0
    blobGen = blobGen + 1   -- an objective may have changed: the game's areas are drawn again
    lastSig = nil
end)

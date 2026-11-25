-- P13Tweaks feature: draw on the world map and share it with your group.
-- Hold Shift and drag with the left mouse button on the world map to draw a line (while Shift is held,
-- dragging draws instead of panning; right-click still goes back, the wheel still zooms). Undo / Clear mine
-- buttons appear in the map's button row while you have lines.
-- Each finished stroke is sent to the group over the hidden addon channel; teammates who also run
-- P13Tweaks see it on their own map, in the sender's class colour. Lines are stored as positions on the
-- map picture (0..1), so they stay put when you zoom or pan. Lines can fade after a few minutes (an option, off by default).
--
-- Messages (prefix "P13M", fields split by "^"). Several short records can share one message, split by "~"
-- (the send queue packs whatever is waiting into as few messages as possible: the game limits the NUMBER of messages).
--   L^<mapID>^<strokeID>^<part>^<parts>^<RRGGBB>^<thickness>^<points>   one stroke (v0.31.17+), in pieces of
--                      <= ~218 characters. The first point of each piece = 4 characters (two 12-bit numbers, x and
--                      y, as base-64 digits); every later point is the step from the one before: 2 characters for a
--                      small step, 3 for a medium one, or "/" + 4 characters (a full position) for a big jump.
--   S^<mapID>^<strokeID>^<part>^<parts>^<RRGGBB>^<points>   the old stroke format (4 characters per point,
--                      thickness in a separate T message) - still understood, no longer sent
--   T^<strokeID>^<thickness>   (old) thickness of a stroke sent with S
--   U^<strokeID>       the sender undid that stroke
--   X                  the sender cleared all their lines
--   A                  the sender cleared EVERY line (everyone's) - receivers clear all of theirs too
local ADDON_NAME, ns = ...

local PREFIX = "P13M"
local MAX_MSG = 250
local PTS_PER_MSG = 50          -- old S messages: 50 points * 4 characters (only used to check incoming ones)
-- The game allows about 10 addon messages at once per prefix, then about one a second. The quest
-- sharing has its own prefix, so drawing can use that whole allowance. If the game still says
-- "too fast", the message goes back in the queue and we wait (see Pump).
local BURST, REFILL = 10, 1.0
local MIN_STEP_PX = 3           -- drawing: a new point once the cursor has moved this many screen pixels
local SIMPLIFY_PX = 1.5         -- when a line is finished, points closer than this to the line through their neighbours are dropped
local lastSimplified           -- debug text about the last finished line
local MIN_STEP_FRAC = 0.00025     -- ...but never closer than this (fraction of the map: about one step of the 12-bit encoding)
local MAX_POINTS = 300          -- per stroke
local MAX_STROKES = 80          -- kept per player
local FADE_SECONDS = 30         -- last seconds of a line's life are a fade-out
local THICKNESS = 3            -- default line thickness (screen pixels)
local THICK_MIN, THICK_MAX = 1, 12
local pendingTh = {}           -- "owner:id" -> thickness that arrived before its line did

-- The brush: how thick new lines are (Shift + mouse wheel on the map changes it). Saved between sessions.
local BRUSHES = { 2, 4, 8 }   -- thin, medium (default), thick
local function BrushIndex()
    local t = tonumber(P13TweaksDB and P13TweaksDB.mapDrawThickness) or BRUSHES[2]
    local best = 1
    for i, v in ipairs(BRUSHES) do   -- (a value saved by the earlier 1-12 version snaps to the nearest)
        if math.abs(v - t) < math.abs(BRUSHES[best] - t) then best = i end
    end
    return best
end
local function Brush() return BRUSHES[BrushIndex()] end

local strokes = {}     -- { owner, id, map, color = {r,g,b}, pts = { {u,v}... }, t = GetTime(), demo }
local partial = {}     -- "owner:id" -> pieces of a stroke still arriving
local version = 0      -- bumps whenever the drawing changes (so the map redraws)
local nextId = 0
local drawing = false  -- draw mode on
local current          -- the stroke being drawn right now
local layer, catcher, undoBtn, clearBtn, clearAllBtn
local linePool, linesUsed, lastSig = {}, 0, nil

local function On() return ns:Get("mapDraw") end
local UpdateButtons   -- set further down
local function Changed()
    version = version + 1
    if UpdateButtons then UpdateButtons() end
end

local function Me() return UnitName("player") end

-- Runs fn after delay seconds; asking again while it's waiting does nothing.
local waiting = {}
local function Later(key, delay, fn)
    if waiting[key] then return end
    waiting[key] = true
    C_Timer.After(delay, function() waiting[key] = nil; fn() end)
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = {}
for i = 1, 64 do DEC[B64:sub(i, i)] = i - 1 end

local function Enc(n)   -- 0..4095 -> 2 characters
    n = math.max(0, math.min(4095, math.floor(n + 0.5)))
    local hi, lo = math.floor(n / 64), n % 64
    return B64:sub(hi + 1, hi + 1) .. B64:sub(lo + 1, lo + 1)
end

local function Dec(s)   -- 2 characters -> 0..4095 (nil if not valid)
    local a, b = DEC[s:sub(1, 1)], DEC[s:sub(2, 2)]
    if a and b then return a * 64 + b end
end

local function DecodePoints(s)
    if #s % 4 ~= 0 or #s > PTS_PER_MSG * 4 then return nil end
    local pts = {}
    for i = 1, #s, 4 do
        local u, v = Dec(s:sub(i, i + 1)), Dec(s:sub(i + 2, i + 3))
        if not (u and v) then return nil end
        pts[#pts + 1] = { u / 4095, v / 4095 }
    end
    return pts
end

-- The newer, shorter point format (L messages): positions as whole numbers 0..4095, each point after the
-- first of a piece written as the step from the previous point.
--   first character 0..31  -> 2 characters: a step of up to 22 in x and y (45 x 45 combinations)
--   first character 32..62 -> 3 characters: a step of up to 177 in x and y (355 x 355 combinations)
--   first character 63 "/" -> followed by a full position (4 characters)
local R2, S2 = 22, 45
local R3, S3 = 177, 355
local LINE_HEADER = 34                 -- room kept for "L^map^id^part^parts^RRGGBB^th^"
local PART_BUDGET = MAX_MSG - LINE_HEADER
local LINE_MAX_PARTS = 12              -- 300 points even if every one were a big jump (5 characters)

local function Q(f) return math.max(0, math.min(4095, math.floor(f * 4095 + 0.5))) end
local function Ch(n) return B64:sub(n + 1, n + 1) end

local function EncStep(dx, dy, x, y)
    if math.abs(dx) <= R2 and math.abs(dy) <= R2 then
        local n = (dy + R2) * S2 + (dx + R2)              -- 0..2024
        return Ch(math.floor(n / 64)) .. Ch(n % 64)
    elseif math.abs(dx) <= R3 and math.abs(dy) <= R3 then
        local n = (dy + R3) * S3 + (dx + R3)              -- 0..126024
        return Ch(32 + math.floor(n / 4096)) .. Ch(math.floor(n / 64) % 64) .. Ch(n % 64)
    end
    return "/" .. Enc(x) .. Enc(y)
end

-- A whole stroke -> a list of point strings, each short enough for one message.
local function EncodeParts(pts)
    local parts, buf, len, px, py = {}, nil, 0, 0, 0
    for i = 1, #pts do
        local x, y = Q(pts[i][1]), Q(pts[i][2])
        local piece = buf and EncStep(x - px, y - py, x, y)
        if not buf or len + #piece > PART_BUDGET then
            if buf then parts[#parts + 1] = table.concat(buf) end
            buf, len = {}, 0
            piece = Enc(x) .. Enc(y)   -- each piece starts from a full position
        end
        buf[#buf + 1] = piece
        len = len + #piece
        px, py = x, y
    end
    if buf then parts[#parts + 1] = table.concat(buf) end
    return parts
end

local function DecodeSteps(s)
    if #s < 4 or #s > MAX_MSG then return nil end
    local x, y = Dec(s:sub(1, 2)), Dec(s:sub(3, 4))
    if not (x and y) then return nil end
    local pts = { { x / 4095, y / 4095 } }
    local i = 5
    while i <= #s do
        local c = DEC[s:sub(i, i)]
        if not c then return nil end
        if c < 32 then
            local d = DEC[s:sub(i + 1, i + 1)]
            if not d then return nil end
            local n = c * 64 + d
            if n >= S2 * S2 then return nil end
            x, y = x + n % S2 - R2, y + math.floor(n / S2) - R2
            i = i + 2
        elseif c < 63 then
            local d, e = DEC[s:sub(i + 1, i + 1)], DEC[s:sub(i + 2, i + 2)]
            if not (d and e) then return nil end
            local n = (c - 32) * 4096 + d * 64 + e
            if n >= S3 * S3 then return nil end
            x, y = x + n % S3 - R3, y + math.floor(n / S3) - R3
            i = i + 3
        else
            x, y = Dec(s:sub(i + 1, i + 2)), Dec(s:sub(i + 3, i + 4))
            if not (x and y) then return nil end
            i = i + 5
        end
        if x < 0 or x > 4095 or y < 0 or y > 4095 then return nil end
        pts[#pts + 1] = { x / 4095, y / 4095 }
    end
    return pts
end

local function HexColor(c) return ("%02x%02x%02x"):format(c[1] * 255 + 0.5, c[2] * 255 + 0.5, c[3] * 255 + 0.5) end
local function ColorFromHex(h)
    return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end

local function MyColor()
    local hex = P13TweaksDB and P13TweaksDB.mapDrawColor   -- picked with the colour ring (Shift + hold right button)
    if type(hex) == "string" and #hex == 6 and tonumber(hex, 16) then return ColorFromHex(hex) end
    local _, class = UnitClass("player")
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return { c.r, c.g, c.b } end
    return { 0.2, 1, 0.6 }
end

---------------------------------------------------------------------------
-- Sending (queued so a long stroke never trips the game's message limit)
---------------------------------------------------------------------------

local function Channel()
    if LE_PARTY_CATEGORY_INSTANCE and LE_PARTY_CATEGORY_HOME
        and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "INSTANCE_CHAT"
    end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

local SendRaw = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local queue, tokens, lastRefill, ticker = {}, BURST, 0, nil

-- Did the game refuse the message for going too fast? (newer clients return a result code,
-- older ones true/false; nil means the client doesn't say, so assume it went)
local R = Enum and Enum.SendAddonMessageResult
local function Throttled(res)
    if res == false then return true end
    if type(res) == "number" and R then
        return res == R.AddonMessageThrottle or res == R.ChannelThrottle
    end
    return false
end

local retries = 0
local function Pump()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - lastRefill) / REFILL)
    lastRefill = now
    local ch = Channel()
    if not ch then wipe(queue) end
    while #queue > 0 and tokens >= 1 do
        local msg = table.remove(queue, 1)
        -- pack the records waiting behind it into the same message while they fit
        while queue[1] and #msg + 1 + #queue[1] <= MAX_MSG do
            msg = msg .. "~" .. table.remove(queue, 1)
        end
        local ok, res = pcall(SendRaw, PREFIX, msg, ch)
        if ok and Throttled(res) and retries < 10 then
            table.insert(queue, 1, msg)   -- try it again on the next tick, in the same order
            retries = retries + 1
            tokens = 0
            break
        end
        retries = 0
        tokens = tokens - 1
    end
    if #queue == 0 and ticker then ticker:Cancel(); ticker = nil end
end

-- Records are queued and sent on the next frame, so everything queued at the same moment (a resend of
-- all my lines, an erase that withdraws lines and sends the pieces) gets packed together by Pump.
local pumpSoon = false
local function Send(msg)
    if not Channel() then return end
    table.insert(queue, msg)
    if pumpSoon then return end
    pumpSoon = true
    C_Timer.After(0, function()
        pumpSoon = false
        Pump()
        if #queue > 0 and not ticker then ticker = C_Timer.NewTicker(0.25, Pump) end
    end)
end

local function SendStroke(s)
    if not Channel() then return end
    local parts = EncodeParts(s.pts)
    local th = math.floor(tonumber(s.th) or THICKNESS)
    for part, body in ipairs(parts) do
        Send(("L^%d^%d^%d^%d^%s^%d^%s"):format(s.map, s.id, part, #parts, HexColor(s.color), th, body))
    end
end

---------------------------------------------------------------------------
-- The drawing itself
---------------------------------------------------------------------------

local function Mine() local out = {} for _, s in ipairs(strokes) do if s.owner == Me() and not s.demo then out[#out + 1] = s end end return out end

-- Undo and Clear mine show while drawing, and any time you have lines on the map (so you can always clear them).
UpdateButtons = function()
    if not (undoBtn and clearBtn and clearAllBtn) then return end
    local want = On() and (drawing or #Mine() > 0) and true or false
    if undoBtn:IsShown() ~= want then undoBtn:SetShown(want) end
    if clearBtn:IsShown() ~= want then clearBtn:SetShown(want) end
    -- "Clear all" is for any line on the map, whoever drew it
    local any = On() and #strokes > 0 and true or false
    if clearAllBtn:IsShown() ~= any then clearAllBtn:SetShown(any) end
end

local function AddStroke(s)
    table.insert(strokes, s)
    -- keep each player's newest MAX_STROKES
    local count = 0
    for i = #strokes, 1, -1 do
        if strokes[i].owner == s.owner then
            count = count + 1
            if count > MAX_STROKES then table.remove(strokes, i) end
        end
    end
    Changed()
end

local function RemoveWhere(fn)
    local removed = false
    for i = #strokes, 1, -1 do
        if fn(strokes[i]) then table.remove(strokes, i); removed = true end
    end
    if removed then Changed() end
    return removed
end

local function FadeMinutes()
    if not ns:Get("mapDrawFade") then return nil end
    return tonumber(ns:Get("mapDrawFadeMinutes")) or 5
end

local function Prune()
    local minutes = FadeMinutes()
    if not minutes then return end
    local limit = minutes * 60
    RemoveWhere(function(s) return GetTime() - s.t > limit end)
end

local function Undo()
    local mine = Mine()
    local s = mine[#mine]
    if not s then return end
    RemoveWhere(function(x) return x == s end)
    Send("U^" .. s.id)
end

local function ClearMine()
    if RemoveWhere(function(s) return s.owner == Me() and not s.demo end) then Send("X") end
end

-- Every line on the map, whoever drew it - on everyone's map in the group.
local function ClearAll()
    RemoveWhere(function() return true end)
    partial = {}
    Send("A")
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function ShortName(sender)
    if Ambiguate then return Ambiguate(sender, "none") end
    return sender
end

-- One piece of a stroke arrived (from an L or an old S message); once all pieces are in, the line is added.
-- th = the thickness carried by an L message (nil for S: that one comes in a T message).
local function GotPiece(who, map, id, part, parts, hex, decoded, th)
    local key = who .. ":" .. id
    local p = partial[key]
    if not p or p.parts ~= parts then
        p = { parts = parts, got = {}, map = tonumber(map), id = tonumber(id), hex = hex }
        partial[key] = p
    end
    p.got[part] = decoded
    local have = 0
    for _ in pairs(p.got) do have = have + 1 end
    if have < parts then return end
    partial[key] = nil
    local all = {}
    for i = 1, parts do
        for _, pt in ipairs(p.got[i]) do
            if #all < MAX_POINTS then all[#all + 1] = pt end
        end
    end
    if th then th = math.max(THICK_MIN, math.min(THICK_MAX, th)) end
    -- a re-sent stroke replaces the old copy
    RemoveWhere(function(s) return s.owner == who and s.id == p.id end)
    AddStroke({ owner = who, id = p.id, map = p.map, color = ColorFromHex(p.hex), pts = all, t = GetTime(),
        th = th or pendingTh[key] })
    pendingTh[key] = nil
end

local function OnRecord(msg, who)
    local kind = msg:sub(1, 1)
    if kind == "L" then
        local map, id, part, parts, hex, th, pts =
            msg:match("^L%^(%d+)%^(%d+)%^(%d+)%^(%d+)%^(%x%x%x%x%x%x)%^(%d+)%^(.*)$")
        if not map then return end
        part, parts = tonumber(part), tonumber(parts)
        if part < 1 or parts < 1 or part > parts or parts > LINE_MAX_PARTS then return end
        local decoded = DecodeSteps(pts)
        if not decoded then return end
        GotPiece(who, map, id, part, parts, hex, decoded, tonumber(th))
    elseif kind == "S" then   -- sent by versions before 0.31.17
        local map, id, part, parts, hex, pts = msg:match("^S%^(%d+)%^(%d+)%^(%d+)%^(%d+)%^(%x%x%x%x%x%x)%^(.*)$")
        if not map then return end
        part, parts = tonumber(part), tonumber(parts)
        if part < 1 or parts < 1 or part > parts or parts > math.ceil(MAX_POINTS / PTS_PER_MSG) then return end
        local decoded = DecodePoints(pts)
        if not decoded then return end
        GotPiece(who, map, id, part, parts, hex, decoded, nil)
    elseif kind == "T" then
        local id, th = msg:match("^T%^(%d+)%^(%d+)$")
        id, th = tonumber(id), tonumber(th)
        if id and th then
            th = math.max(THICK_MIN, math.min(THICK_MAX, th))
            local found = false
            for _, s in ipairs(strokes) do
                if s.owner == who and s.id == id then s.th, found = th, true end
            end
            if found then Changed() else pendingTh[who .. ":" .. id] = th end   -- the line is still arriving
        end
    elseif kind == "U" then
        local id = tonumber(msg:match("^U%^(%d+)"))
        if id then RemoveWhere(function(s) return s.owner == who and s.id == id end) end
    elseif kind == "X" then
        RemoveWhere(function(s) return s.owner == who end)
    elseif kind == "A" then   -- somebody cleared every line, for everyone
        RemoveWhere(function() return true end)
        partial = {}
        ns:Print(who .. " cleared all the map drawings.")
    end
end

local function OnMessage(msg, sender)
    if not On() then return end
    local who = ShortName(sender)
    if who == Me() then return end
    for rec in msg:gmatch("[^~]+") do OnRecord(rec, who) end   -- one message can carry several records
end

---------------------------------------------------------------------------
-- Group changes: send my lines to newcomers, drop lines of people who left
---------------------------------------------------------------------------

local roster = {}

local function GroupNames()
    local t = {}
    local raid = IsInRaid()
    for i = 1, (GetNumGroupMembers() or 0) do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            -- just the name: a realm part that appears and disappears made people look like newcomers each time
            local name = UnitName(unit)
            if name then t[name] = true end
        end
    end
    return t
end

local function OnRoster()
    local now = Channel() and GroupNames() or {}
    -- an owner's name may carry a realm ("Ann-Realm" / "Ann Realm"): match on the name at the start
    local function InGroupNow(owner)
        local o = tostring(owner):lower():gsub("[%s%-'_]", "")
        for name in pairs(now) do
            local n = name:lower():gsub("[%s%-'_]", "")
            if n ~= "" and o:sub(1, #n) == n then return true end
        end
        return false
    end
    RemoveWhere(function(s) return s.owner ~= Me() and not s.demo and not InGroupNow(s.owner) end)
    local someoneNew = false
    for name in pairs(now) do if not roster[name] then someoneNew = true end end
    roster = now
    if someoneNew and On() then
        Later("resend", 3, function()
            for _, s in ipairs(Mine()) do SendStroke(s) end   -- the newcomer's addon also sends theirs to me
        end)
    end
end

---------------------------------------------------------------------------
-- Drawing the lines on the map
---------------------------------------------------------------------------

-- Thick segments have flat ends, which leave gaps at the corners. A round dot as wide as the line at each
-- point where segments meet fills them in. Only used for lines DOT_FROM px or thicker (thinner gaps don't show).
local DOT_FROM = 4
local dotPool, dotsUsed = {}, 0

-- Stacking: lines drawn later sit on top of earlier ones. Each line gets its own slot in the frame's
-- drawing layers (4 layers x 16 sub-levels = 64 slots), newest on top; lines older than the newest 64
-- share the bottom slot. `i` is the line's place in the list (oldest first), `n` how many there are.
local SLOT_LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY" }
local function SlotLayer(i, n)
    local slot = math.max(1, #SLOT_LAYERS * 16 - (n - i))
    return SLOT_LAYERS[math.floor((slot - 1) / 16) + 1], (slot - 1) % 16 - 8
end
local function MakeDot(parent)
    local t = parent:CreateTexture(nil, "OVERLAY")
    if parent.CreateMaskTexture and t.AddMaskTexture then
        local mask = parent:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(t)
        t:AddMaskTexture(mask)
    end
    return t
end

local function GetLine()
    linesUsed = linesUsed + 1
    local l = linePool[linesUsed]
    if not l then
        l = layer:CreateLine(nil, "OVERLAY")
        linePool[linesUsed] = l
    end
    l:Show()
    return l
end

-- The painted map (and its "explored area" pieces) sits in frames whose level/strata we can't know in
-- advance, and a line layer below them is hidden. So look at what's in the map canvas and put the
-- layer above all of it.
local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local lastRaise = 0
local function RaiseLayer(child, force)
    if not force and GetTime() - lastRaise < 1 then return end
    lastRaise = GetTime()
    local kids = { child:GetChildren() }
    local topName = layer:GetFrameStrata()
    local top = STRATA[topName] or 1
    for _, k in ipairs(kids) do
        if k ~= layer then
            local name = k:GetFrameStrata()
            if (STRATA[name] or 1) > top then top, topName = STRATA[name], name end
        end
    end
    if layer:GetFrameStrata() ~= topName then layer:SetFrameStrata(topName) end
    local maxLevel = child:GetFrameLevel()
    for _, k in ipairs(kids) do
        if k ~= layer and k:GetFrameStrata() == topName then
            maxLevel = math.max(maxLevel, k:GetFrameLevel())
        end
    end
    local want = math.min(9999, maxLevel + 1)
    if layer:GetFrameLevel() ~= want then layer:SetFrameLevel(want) end
    return #kids, maxLevel, topName
end

-- The stroke's points on the map being viewed. Strokes belong to the map they were drawn on; on a
-- related map (the zone you zoomed into, the continent you zoomed out to) the points are converted,
-- so drawings survive the map changing level. Converted copies are kept until the stroke changes.
local function StrokeOn(s, mapID)
    if s.map == mapID then return s.pts end
    s.conv = s.conv or {}
    local c = s.conv[mapID]
    if c and c.n == #s.pts then return c.pts or nil end
    local out
    if ns.MapPoint then
        out = {}
        for i, p in ipairs(s.pts) do
            local u, v = ns.MapPoint(s.map, mapID, p[1], p[2])
            if not u then out = nil break end
            out[i] = { u, v }
        end
    end
    s.conv[mapID] = { n = #s.pts, pts = out or false }
    return out
end

local function Redraw(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (layer and child) then return end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    local st = lastSig
    if not st then st = {}; lastSig = st end
    if ns.SigSame(st, version, mapID, math.floor(scale * 1e5), math.floor(W), math.floor(GetTime() / 3),
        On() and true or false) and not force then return end

    for i = 1, linesUsed do linePool[i]:Hide() end
    linesUsed = 0
    for i = 1, dotsUsed do dotPool[i]:Hide() end
    dotsUsed = 0
    if not On() then return end

    RaiseLayer(child, force)
    layer:SetScale(1 / scale)
    layer:SetSize(W * scale, H * scale)
    local sx, sy = W * scale, H * scale
    local minutes = FadeMinutes()
    local now = GetTime()
    for si, s in ipairs(strokes) do
        local pts = StrokeOn(s, mapID)
        if pts and #pts >= 2 then
            local lyr, sub = SlotLayer(si, #strokes)
            local alpha = 1
            if minutes then
                local left = minutes * 60 - (now - s.t)
                if left < FADE_SECONDS then alpha = math.max(0.1, left / FADE_SECONDS) end
            end
            for i = 2, #pts do
                if linesUsed >= 3000 then break end
                local a, b = pts[i - 1], pts[i]
                local l = GetLine()
                l:SetDrawLayer(lyr, sub)
                l:SetThickness(s.th or THICKNESS)
                l:SetColorTexture(s.color[1], s.color[2], s.color[3], alpha)
                l:SetStartPoint("TOPLEFT", layer, a[1] * sx, -a[2] * sy)
                l:SetEndPoint("TOPLEFT", layer, b[1] * sx, -b[2] * sy)
            end
            local th = s.th or THICKNESS
            if th >= DOT_FROM then
                for i = 1, #pts do
                    if dotsUsed >= 3000 then break end
                    dotsUsed = dotsUsed + 1
                    local d = dotPool[dotsUsed]
                    if not d then d = MakeDot(layer); dotPool[dotsUsed] = d end
                    d:SetDrawLayer(lyr, sub)
                    d:SetSize(th, th)
                    d:ClearAllPoints()
                    d:SetPoint("CENTER", layer, "TOPLEFT", pts[i][1] * sx, -pts[i][2] * sy)
                    d:SetColorTexture(s.color[1], s.color[2], s.color[3], alpha)
                    d:Show()
                end
            end
        end
    end
end

-- Lets the tile-map zoom redraw the lines in the same frame it moves the map (see MapSheetZoom.lua).
ns.RedrawMapDrawings = function() Redraw(false) end

---------------------------------------------------------------------------
-- Draw mode: the mouse catcher over the map
---------------------------------------------------------------------------

local function CursorOnMap()
    local sc = WorldMapFrame.ScrollContainer
    if not sc.GetNormalizedCursorPosition then return end
    local u, v = sc:GetNormalizedCursorPosition()
    if u and v and u >= 0 and u <= 1 and v >= 0 and v <= 1 then return u, v end
end

-- The mouse catcher over the map is active while Draw is on, while Shift is held (hold Shift and drag
-- to draw without the button), and while a stroke is still being drawn.
local shiftHeld = false
local altHeld = false       -- Alt held over the map: the eraser (see below)
local passRight
local function RefreshCatcher()
    if not catcher then return end
    -- Shift + right button is the colour ring, so the catcher swallows right clicks (no "back a level")
    -- while it is on; with the ring switched off, right-click passes through as before.
    local wantPass = not ns:Get("mapDrawPicker")
    if wantPass ~= passRight and catcher.SetPassThroughButtons then
        passRight = wantPass
        if wantPass then pcall(catcher.SetPassThroughButtons, catcher, "RightButton") else pcall(catcher.SetPassThroughButtons, catcher) end
    end
    local active = On() and (drawing or shiftHeld or altHeld or current ~= nil) and true or false
    if catcher:IsShown() ~= active then catcher:SetShown(active) end
    catcher:EnableMouse(active)
end

-- Ramer-Douglas-Peucker: keep only the points that matter. A point is dropped when it lies within
-- SIMPLIFY_PX screen pixels (at the finest zoom the line was drawn at) of the straight line between the
-- points kept on either side of it. The ends always stay. Distances are measured in screen pixels.
local function Simplify(pts, pxU, pxV)
    local n = #pts
    if n <= 2 then return pts end
    local eps = math.max(SIMPLIFY_PX, MIN_STEP_FRAC * math.min(pxU, pxV))   -- (never finer than the encoding)
    local keep = { [1] = true, [n] = true }
    local stack = { { 1, n } }
    while #stack > 0 do
        local a, b = unpack(table.remove(stack))
        local ax, ay, bx, by = pts[a][1] * pxU, pts[a][2] * pxV, pts[b][1] * pxU, pts[b][2] * pxV
        local dx, dy = bx - ax, by - ay
        local len2 = dx * dx + dy * dy
        local far, farD = nil, eps
        for i = a + 1, b - 1 do
            local px, py = pts[i][1] * pxU, pts[i][2] * pxV
            local d
            if len2 == 0 then
                d = math.sqrt((px - ax) ^ 2 + (py - ay) ^ 2)
            else
                local t = math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
                d = math.sqrt((px - ax - t * dx) ^ 2 + (py - ay - t * dy) ^ 2)
            end
            if d > farD then far, farD = i, d end
        end
        if far then
            keep[far] = true
            stack[#stack + 1] = { a, far }
            stack[#stack + 1] = { far, b }
        end
    end
    local out = {}
    for i = 1, n do if keep[i] then out[#out + 1] = pts[i] end end
    return out
end

local function EndStroke()
    if not current then return end
    local s = current
    current = nil
    if catcher then catcher:SetScript("OnUpdate", nil) end
    -- tidy the line before it is sent: same shape, far fewer points
    if #s.pts > 2 and s.pxU and s.pxV then
        local before = #s.pts
        s.pts = Simplify(s.pts, s.pxU, s.pxV)
        s.conv, s.sheet = nil, nil   -- cached conversions were for the old points
        lastSimplified = ("last line: %d -> %d pts"):format(before, #s.pts)
    end
    if #s.pts >= 2 then
        nextId = nextId + 1
        s.id = nextId
        s.t = GetTime()
        SendStroke(s)
    else
        RemoveWhere(function(x) return x == s end)
    end
    Changed()
    RefreshCatcher()
end

local function BeginStroke(mapID, u, v)
    current = { owner = Me(), id = 0, map = mapID, color = MyColor(), pts = { { u, v } }, t = GetTime(), th = Brush() }
    table.insert(strokes, current)
    Changed()
end

-- pxU, pxV: how many screen pixels the whole map is wide / high right now. A new point is kept once the
-- cursor has moved MIN_STEP_PX on screen, so a line drawn zoomed in is as smooth as one drawn zoomed out.
-- At the point limit, every second point of the line so far is dropped (the ends stay) to make room.
local function AddPoint(cu, cv, pxU, pxV)
    if not current then return end
    local pts = current.pts
    local last = pts[#pts]
    -- remember the finest zoom the line was drawn at (the tidy-up at the end measures in pixels of that)
    if not current.pxU or pxU > current.pxU then current.pxU, current.pxV = pxU, pxV end
    local dx, dy = cu - last[1], cv - last[2]
    if dx * dx + dy * dy < MIN_STEP_FRAC ^ 2 then return end
    if (dx * pxU) ^ 2 + (dy * pxV) ^ 2 < MIN_STEP_PX ^ 2 then return end
    if #pts >= MAX_POINTS then
        local thin = { pts[1] }
        for i = 3, #pts - 1, 2 do thin[#thin + 1] = pts[i] end
        thin[#thin + 1] = pts[#pts]
        pts = thin
        current.pts = pts
        current.thinned = (current.thinned or 0) + 1
    end
    pts[#pts + 1] = { cu, cv }
    Changed()
end

-- Debug readout (option "mapDrawDebug"): how many points are registered.
local function DebugText()
    local total, mine = 0, 0
    for _, s in ipairs(strokes) do
        total = total + #s.pts
        if s.owner == Me() then mine = mine + 1 end
    end
    local cur = current and #current.pts or 0
    return ("draw: current %d pts%s | all %d pts | %d strokes (%d mine) | step %d px%s"):format(
        cur, current and current.thinned and (" (thinned x" .. current.thinned .. ")") or "", total, #strokes, mine, MIN_STEP_PX,
        lastSimplified and (" | " .. lastSimplified) or "")
end

local function StartStroke()
    local mapID = WorldMapFrame:GetMapID()
    local u, v = CursorOnMap()
    if not (mapID and u) then return end
    BeginStroke(mapID, u, v)
    catcher:SetScript("OnUpdate", function()
        if not current then return end
        local cu, cv = CursorOnMap()
        if cu then
            local sc = WorldMapFrame.ScrollContainer
            local scale = sc:GetCanvasScale()
            AddPoint(cu, cv, sc.Child:GetWidth() * scale, sc.Child:GetHeight() * scale)
        end
    end)
end

-- For the tile-map window (MapSheet.lua): it draws the same strokes on its own sheet. It converts its
-- tile positions to a map (u, v) itself and hands them to us, so lines are shared and shown on the normal map too.
ns.SheetDraw = {
    enabled = On,
    version = function() return version end,
    strokes = function() return strokes end,
    drawing = function() return current ~= nil end,
    begin = function(mapID, u, v) if On() then EndStroke(); BeginStroke(mapID, u, v) end end,
    add = AddPoint,
    finish = EndStroke,
    undo = Undo,
    clearMine = ClearMine,
    hasMine = function() return #Mine() > 0 end,
    alpha = function(s)
        local minutes = FadeMinutes()
        if not minutes then return 1 end
        local left = minutes * 60 - (GetTime() - s.t)
        if left < FADE_SECONDS then return math.max(0.1, left / FADE_SECONDS) end
        return 1
    end,
    thicknessOf = function(s) return s.th or THICKNESS end,
    dotFrom = DOT_FROM,
    slotLayer = SlotLayer,
    makeDot = MakeDot,
    wheel = function(delta) ns.DrawBrushWheel(delta) end,
    debugText = function() return ns:Get("mapDrawDebug") and DebugText() or nil end,
}

local function SetDrawing(on)
    on = on and On() and true or false
    if not on then EndStroke() end
    drawing = on
    RefreshCatcher()
    UpdateButtons()
end

---------------------------------------------------------------------------
-- Eraser: hold Alt and drag with the left button over your lines. Everything of your lines inside a circle
-- around the cursor is cut out, so a line splits into pieces (or shrinks, or goes). Only your own lines.
-- When you let go, the old lines are withdrawn from the group and the pieces are sent as new lines.
---------------------------------------------------------------------------

-- Eraser radius, in the map pane's own pixels (the same units the lines are drawn in). Alt + mouse wheel
-- changes it; it is saved between sessions.
local ERASE_MIN, ERASE_MAX, ERASE_DEFAULT = 4, 60, 12
local function EraserPx()
    local r = tonumber(P13TweaksDB and P13TweaksDB.mapDrawEraser) or ERASE_DEFAULT
    return math.max(ERASE_MIN, math.min(ERASE_MAX, r))
end

function ns.EraserWheel(delta)
    local r = EraserPx()
    local new = math.floor(r * (delta > 0 and 1.2 or 1 / 1.2) + 0.5)
    if new == r then new = r + (delta > 0 and 1 or -1) end   -- (small sizes: always move at least a pixel)
    P13TweaksDB.mapDrawEraser = math.max(ERASE_MIN, math.min(ERASE_MAX, new))
end

local erasing = false        -- the left button is down and we are cutting
local erasedIds = {}         -- ids of lines cut during this drag (to withdraw from the group at the end)
local eraserDot              -- the circle that follows the cursor while Alt is held

-- The pieces of a line (points {u, v}) left after cutting out the ellipse around (cu, cv) with radii (ru, rv)
-- (an ellipse because map units are not the same size across and down). Returns nil if the line is untouched,
-- otherwise a list of point lists (possibly empty = the whole line was erased).
local function ErasePieces(pts, cu, cv, ru, rv)
    local n = #pts
    if n < 2 or ru <= 0 or rv <= 0 then return nil end
    local P = {}
    for i = 1, n do P[i] = { (pts[i][1] - cu) / ru, (pts[i][2] - cv) / rv } end   -- (the eraser is the unit circle here)
    local pieces, cur, changed = {}, nil, false
    local function Close()
        if cur and #cur >= 2 then pieces[#pieces + 1] = cur end
        cur = nil
    end
    local function Back(q) return { cu + q[1] * ru, cv + q[2] * rv } end
    for i = 1, n - 1 do
        local a, b = P[i], P[i + 1]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local A = dx * dx + dy * dy
        local lo, hi
        if A > 1e-12 then
            local B = 2 * (a[1] * dx + a[2] * dy)
            local C = a[1] * a[1] + a[2] * a[2] - 1
            local disc = B * B - 4 * A * C
            if disc > 0 then
                local sq = math.sqrt(disc)
                lo, hi = math.max(0, (-B - sq) / (2 * A)), math.min(1, (-B + sq) / (2 * A))
                if lo >= hi then lo = nil end
            end
        elseif a[1] * a[1] + a[2] * a[2] < 1 then
            lo, hi = 0, 1
        end
        if not lo then
            if not cur then cur = { pts[i] } end
            cur[#cur + 1] = pts[i + 1]
        else
            changed = true
            if lo > 0 then   -- the part before the circle stays, up to where the segment enters it
                if not cur then cur = { pts[i] } end
                cur[#cur + 1] = Back({ a[1] + dx * lo, a[2] + dy * lo })
            end
            Close()
            if hi < 1 then   -- and a new piece starts where it leaves the circle
                cur = { Back({ a[1] + dx * hi, a[2] + dy * hi }), pts[i + 1] }
            end
        end
    end
    Close()
    if not changed then return nil end
    return pieces
end

-- Cut the eraser circle at map position (cu, cv) out of each of my lines.
local function EraseAt(cu, cv)
    local sc = WorldMapFrame.ScrollContainer
    local scale = sc:GetCanvasScale()
    local pxU, pxV = sc.Child:GetWidth() * scale, sc.Child:GetHeight() * scale
    if not (pxU > 0 and pxV > 0 and pxU < math.huge) then return end
    local viewMap = WorldMapFrame:GetMapID()
    local px = EraserPx()
    local ru, rv = px / pxU, px / pxV
    for i = #strokes, 1, -1 do
        local s = strokes[i]
        if s.owner == Me() and not s.demo and s ~= current then
            -- the eraser's centre and radii on the map this line was drawn on (a related map when you have zoomed in/out)
            local mu, mv, mru, mrv = cu, cv, ru, rv
            if s.map ~= viewMap then
                mu = nil
                if ns.MapPoint then   -- (not "ns.MapPoint and ns.MapPoint(...)": that keeps only the first value)
                    local c1, c2 = ns.MapPoint(viewMap, s.map, cu, cv)
                    local a1 = ns.MapPoint(viewMap, s.map, cu + ru, cv)
                    local _, b2 = ns.MapPoint(viewMap, s.map, cu, cv + rv)
                    if c1 and c2 and a1 and b2 then
                        mu, mv, mru, mrv = c1, c2, math.abs(a1 - c1), math.abs(b2 - c2)
                    end
                end
            end
            local pieces = mu and ErasePieces(s.pts, mu, mv, mru, mrv)
            if pieces then
                if not s.p13dirty and s.id and s.id > 0 then erasedIds[#erasedIds + 1] = s.id end
                table.remove(strokes, i)
                for k = #pieces, 1, -1 do   -- the pieces take the old line's place, in order
                    table.insert(strokes, i, { owner = s.owner, id = 0, map = s.map, color = s.color, pts = pieces[k],
                        t = s.t, th = s.th, p13dirty = true })
                end
                Changed()
            end
        end
    end
end

-- Done cutting: tell the group (withdraw the old lines, send the pieces as new lines).
local function FinishErase()
    erasing = false
    local any = #erasedIds > 0
    for _, id in ipairs(erasedIds) do Send("U^" .. id) end
    erasedIds = {}
    for _, s in ipairs(strokes) do
        if s.p13dirty then
            s.p13dirty = nil
            nextId = nextId + 1
            s.id = nextId
            SendStroke(s)
            any = true
        end
    end
    if any then Changed() end
end

local function SetupEraser(sc)
    eraserDot = MakeDot(catcher)
    eraserDot:SetDrawLayer("OVERLAY", 7)
    eraserDot:SetSize(EraserPx() * 2, EraserPx() * 2)
    eraserDot:SetColorTexture(1, 1, 1, 0.3)
    eraserDot:Hide()
    local f = CreateFrame("Frame", nil, WorldMapFrame)
    f:SetScript("OnUpdate", function()
        if not (altHeld and not shiftHeld) then
            if erasing then FinishErase() end
            if eraserDot:IsShown() then eraserDot:Hide() end
            return
        end
        local cu, cv = CursorOnMap()
        if not cu then
            if eraserDot:IsShown() then eraserDot:Hide() end
            if erasing and not IsMouseButtonDown("LeftButton") then FinishErase() end
            return
        end
        -- the circle follows the cursor (and shows the current size)
        eraserDot:SetSize(EraserPx() * 2, EraserPx() * 2)
        local es = sc:GetEffectiveScale()
        local x, y = GetCursorPosition()
        eraserDot:ClearAllPoints()
        eraserDot:SetPoint("CENTER", sc, "BOTTOMLEFT", x / es - sc:GetLeft(), y / es - sc:GetBottom())
        eraserDot:Show()
        if IsMouseButtonDown("LeftButton") then
            erasing = true
            EraseAt(cu, cv)
        elseif erasing then
            FinishErase()
        end
    end)
end

---------------------------------------------------------------------------
-- Colour ring: hold Shift, press and HOLD the right mouse button on the map (or the tile map); a ring of
-- swatches opens around the cursor. Move toward one and let go to pick it (let go in the middle = no change).
-- The first swatch is your class colour, the default. New lines use the picked colour; lines already
-- drawn keep theirs. The colour is saved between sessions.
---------------------------------------------------------------------------

local SWATCHES = {   -- first one = class colour (hex nil)
    { "Class colour", nil },
    { "Red", "ff3333" }, { "Orange", "ff8c1a" }, { "Yellow", "ffe619" }, { "Green", "4dff4d" },
    { "Blue", "4d80ff" }, { "Purple", "bf66ff" }, { "White", "ffffff" },
}
local RING_RADIUS, SWATCH_SIZE, DEAD_ZONE = 70, 34, 22
local ring, ringShown, ringCx, ringCy, ringPick

local function SwatchColor(i)
    local hex = SWATCHES[i][2]
    if hex then return ColorFromHex(hex) end
    local _, class = UnitClass("player")
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return { c.r, c.g, c.b } end
    return { 0.2, 1, 0.6 }
end

local function BuildRing()
    ring = CreateFrame("Frame", nil, UIParent)
    ring:SetSize(1, 1)
    ring:SetFrameStrata("TOOLTIP")
    ring:Hide()
    ring.swatch = {}
    for i = 1, #SWATCHES do
        local border = ring:CreateTexture(nil, "ARTWORK")
        border:SetColorTexture(1, 1, 1, 1)
        local tex = ring:CreateTexture(nil, "OVERLAY")
        local c = SwatchColor(i)
        tex:SetColorTexture(c[1], c[2], c[3], 1)
        -- round: a circular mask on each (if this client has mask textures; otherwise they stay square)
        if ring.CreateMaskTexture and tex.AddMaskTexture then
            for _, t in ipairs({ tex, border }) do
                local mask = ring:CreateMaskTexture()
                mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                mask:SetAllPoints(t)
                t:AddMaskTexture(mask)
            end
        end
        ring.swatch[i] = { tex = tex, border = border }
    end
    -- the middle shows the colour in use right now (a white-rimmed disc)
    ring.currentRim = ring:CreateTexture(nil, "ARTWORK")
    ring.currentRim:SetColorTexture(1, 1, 1, 1)
    ring.currentRim:SetSize(32, 32)
    ring.currentRim:SetPoint("CENTER")
    ring.current = ring:CreateTexture(nil, "OVERLAY")
    ring.current:SetSize(26, 26)
    ring.current:SetPoint("CENTER")
    if ring.CreateMaskTexture and ring.current.AddMaskTexture then
        for _, t in ipairs({ ring.currentRim, ring.current }) do
            local mask = ring:CreateMaskTexture()
            mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(t)
            t:AddMaskTexture(mask)
        end
    end
end

-- which swatch the cursor points at (nil in the middle)
local function RingPick()
    local px, py = GetCursorPosition()
    local es = UIParent:GetEffectiveScale()
    local dx, dy = px / es - ringCx, py / es - ringCy
    if dx * dx + dy * dy < DEAD_ZONE ^ 2 then return nil end
    local angle = math.atan2(dx, dy)   -- 0 = up, clockwise
    if angle < 0 then angle = angle + 2 * math.pi end
    return math.floor(angle / (2 * math.pi) * #SWATCHES + 0.5) % #SWATCHES + 1
end

local function LayoutRing()
    for i, sw in ipairs(ring.swatch) do
        local a = (i - 1) * 2 * math.pi / #SWATCHES
        local size = (i == ringPick) and SWATCH_SIZE + 12 or SWATCH_SIZE
        sw.tex:ClearAllPoints()
        sw.tex:SetPoint("CENTER", ring, "CENTER", RING_RADIUS * math.sin(a), RING_RADIUS * math.cos(a))
        sw.tex:SetSize(size, size)
        sw.border:ClearAllPoints()
        sw.border:SetPoint("CENTER", sw.tex, "CENTER")
        sw.border:SetSize(size + 4, size + 4)
        sw.border:SetShown(i == ringPick)
    end
end

local function OverMap()
    local sheet = _G.P13SheetFrame
    if sheet and sheet:IsShown() then return sheet:IsMouseOver() end
    local sc = WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame.ScrollContainer
    return sc and sc:IsMouseOver() or false
end

local ringDriver = CreateFrame("Frame")
ringDriver:SetScript("OnUpdate", function()
    local down = IsMouseButtonDown("RightButton")
    if not ringShown then
        -- open: Shift is held, the right button just went down over the map
        if down and IsShiftKeyDown() and ns:Get("mapDraw") and ns:Get("mapDrawPicker") and OverMap() then
            if not ring then BuildRing() end
            local px, py = GetCursorPosition()
            local es = UIParent:GetEffectiveScale()
            ringCx, ringCy, ringPick = px / es, py / es, nil
            ring:ClearAllPoints()
            ring:SetPoint("CENTER", UIParent, "BOTTOMLEFT", ringCx, ringCy)
            for i, sw in ipairs(ring.swatch) do   -- (the class colour can change with the character)
                local c = SwatchColor(i)
                sw.tex:SetColorTexture(c[1], c[2], c[3], 1)
            end
            local cur = MyColor()
            ring.current:SetColorTexture(cur[1], cur[2], cur[3], 1)
            ringShown = true
            LayoutRing()
            ring:Show()
        end
        return
    end
    if down then
        local pick = RingPick()
        if pick ~= ringPick then ringPick = pick; LayoutRing() end
    else
        ringShown = false
        ring:Hide()
        local pick = RingPick()
        if pick then
            P13TweaksDB.mapDrawColor = SWATCHES[pick][2]   -- nil = class colour
        end
    end
end)

---------------------------------------------------------------------------
-- Brush thickness: Shift + mouse wheel on the map (or the tile map). A round preview of the thickness
-- follows the cursor for a moment. A line being drawn changes thickness as you scroll; otherwise it
-- sets the thickness of the next lines.
---------------------------------------------------------------------------

local preview, previewUntil

function ns.DrawBrushWheel(delta)
    -- wheel up = one size thicker, wheel down = one size thinner; stops at the ends (no wrapping round)
    local t = BRUSHES[math.max(1, math.min(#BRUSHES, BrushIndex() + (delta > 0 and 1 or -1)))]
    P13TweaksDB.mapDrawThickness = t
    if current then current.th = t; Changed() end
    if not preview then
        preview = CreateFrame("Frame", nil, UIParent)
        preview:SetFrameStrata("TOOLTIP")
        preview.rim = preview:CreateTexture(nil, "ARTWORK")
        preview.rim:SetColorTexture(1, 1, 1, 1)
        preview.dot = preview:CreateTexture(nil, "OVERLAY")
        if preview.CreateMaskTexture and preview.dot.AddMaskTexture then
            for _, tx in ipairs({ preview.rim, preview.dot }) do
                local mask = preview:CreateMaskTexture()
                mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                mask:SetAllPoints(tx)
                tx:AddMaskTexture(mask)
            end
        end
        preview:SetScript("OnUpdate", function(self)
            if GetTime() > previewUntil then self:Hide() return end
            local px, py = GetCursorPosition()
            local es = UIParent:GetEffectiveScale()
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", px / es, py / es)
        end)
    end
    -- a line of t pixels is t * (the map's scale / the UI's scale) UI units wide
    local sheet = _G.P13SheetFrame
    local ref = (sheet and sheet:IsShown()) and sheet or WorldMapFrame
    local size = t * ref:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local c = (current and current.color) or MyColor()
    preview.dot:SetSize(size, size)
    preview.dot:SetPoint("CENTER")
    preview.dot:SetColorTexture(c[1], c[2], c[3], 1)
    preview.rim:SetSize(size + 3, size + 3)
    preview.rim:SetPoint("CENTER")
    preview:SetSize(size + 3, size + 3)
    previewUntil = GetTime() + 1.2
    preview:Show()
end

---------------------------------------------------------------------------
-- Options and commands
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "mapDraw",
    type = "toggle",
    label = "Draw on the map and share it with my group",
    tooltip = "Hold Shift and drag with the left mouse button on the world map (or the tile map) to draw a line. Teammates who also have P13Tweaks see your lines on their map (and you see theirs), each in the sender's class colour. Undo and Clear mine buttons appear in the map's button row while you have lines. While Shift is held, dragging draws instead of panning the map.",
    default = true,
    onChange = function(on)
        if not on then SetDrawing(false) end
        RefreshCatcher()
        Changed()
    end,
})

ns:RegisterOption({
    key = "mapDrawErase",
    type = "toggle",
    label = "Eraser: hold Alt and drag over your lines",
    tooltip = "Hold Alt on the world map and drag with the left mouse button over your lines to cut the part under the circle out of them: a line shrinks, splits in two, or goes. Only your own lines. Your group sees the change when you let go. While Alt is held, dragging erases instead of panning the map, and the mouse wheel makes the eraser bigger or smaller (it remembers its size).",
    default = true,
    onChange = function(on)
        altHeld = on and IsAltKeyDown() and WorldMapFrame and WorldMapFrame:IsShown() and true or false
        RefreshCatcher()
    end,
})

ns:RegisterOption({
    key = "mapDrawPicker",
    type = "toggle",
    label = "Colour ring: Shift + hold right button on the map",
    tooltip = "Hold Shift, press and hold the right mouse button on the world map or the tile map, and a ring of colours opens around the cursor. Move toward one and let go to use it for new lines (the first one is your class colour). Shift + right-click then no longer goes back a map level; plain right-click still does.",
    default = true,
    onChange = function() RefreshCatcher() end,
})

ns:RegisterOption({
    key = "mapDrawDebug",
    type = "toggle",
    label = "Show drawing point counts on the map (debug)",
    tooltip = "A small line of text at the bottom of the world map and the tile map: how many points the line you are drawing has, how many points and lines there are in all, and the drawing step. Handy while checking how smooth lines are.",
    default = true,
    onChange = function() Changed() end,
})

ns:RegisterOption({
    key = "mapDrawFade",
    type = "toggleNumber",
    label = "Fade map drawings after a while",
    before = "Fade drawings after",
    after = "minutes",
    numberKey = "mapDrawFadeMinutes",
    numberDefault = 5,
    tooltip = "Lines on the map (yours and your teammates') fade out and disappear after this many minutes. Turn it off to keep them until you press Clear mine, type /p13 mapdraw clear or reload.",
    default = false,
    onChange = function() Changed() end,
})

ns:RegisterCommand("mapdraw", "map drawing: /p13 mapdraw clear (your lines), /p13 mapdraw demo (pretend teammates)", function(arg)
    arg = strtrim(arg or ""):lower()
    if arg == "clear" then
        ClearMine()
        ns:Print("Your map lines are cleared (your group's copies too).")
    elseif arg == "clear all" then
        ClearAll()
        ns:Print("Cleared every map drawing, for everyone in your group.")
    elseif arg == "debug" then
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        if not (sc and layer) then ns:Print("The map isn't ready."); return end
        local n, maxLevel, strata = RaiseLayer(sc.Child, true)
        ns:Print(("draw layer: level %d, strata %s | map canvas: level %d, %d child frames, highest child level %s (strata %s) | %d lines on %d strokes | map %s"):format(
            layer:GetFrameLevel(), layer:GetFrameStrata(), sc.Child:GetFrameLevel(), n or 0, tostring(maxLevel), tostring(strata),
            linesUsed, #strokes, tostring(WorldMapFrame:GetMapID())))
    elseif arg == "demo" then
        local had = RemoveWhere(function(s) return s.demo end)
        if had then ns:Print("Pretend teammates' lines removed."); return end
        local mapID = WorldMapFrame and WorldMapFrame:GetMapID()
        if not mapID then ns:Print("Open the world map first, then try again."); return end
        local function Wave(owner, color, y0, amp)
            local pts = {}
            for i = 0, 40 do
                local u = 0.15 + 0.7 * i / 40
                pts[#pts + 1] = { u, y0 + amp * math.sin(i / 4) }
            end
            AddStroke({ owner = owner, id = 1, map = mapID, color = color, pts = pts, t = GetTime(), demo = true })
        end
        Wave("Demo Ann", { 1, 0.5, 0.1 }, 0.35, 0.06)
        Wave("Demo Bob", { 0.3, 0.7, 1 }, 0.6, 0.08)
        ns:Print("Added two pretend teammates' lines to this map. Type /p13 mapdraw demo again to remove them.")
        Redraw(true)
    else
        ns:Print("Open the world map, hold Shift and drag to draw. /p13 mapdraw clear removes your lines; /p13 mapdraw demo tries it alone.")
    end
end)

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Keeping your lines through /reload and logout
---------------------------------------------------------------------------
-- Only YOUR lines are saved (per character). Your group's lines come back by themselves: when you rejoin the
-- group view after a reload everybody's addon sends its lines again, and a re-sent line replaces its old copy.
-- Points are saved at full precision (the 12-bit network form is too coarse when zoomed far in).

local function CharKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end

local function SaveStrokes()
    P13TweaksDB.mapDrawSaved = P13TweaksDB.mapDrawSaved or {}
    local list = {}
    if ns:Get("mapDrawKeep") then
        for _, s in ipairs(Mine()) do
            if s ~= current and #s.pts >= 2 then   -- (a line still being drawn is not finished)
                local parts = {}
                for i, p in ipairs(s.pts) do parts[i] = ("%.5f,%.5f"):format(p[1], p[2]) end
                list[#list + 1] = { map = s.map, id = s.id, hex = HexColor(s.color), th = s.th,
                    pts = table.concat(parts, ";"), age = GetTime() - s.t, ts = time() }
            end
        end
    end
    P13TweaksDB.mapDrawSaved[CharKey()] = (#list > 0) and list or nil
end

local function RestoreStrokes()
    if not ns:Get("mapDrawKeep") then return end
    local saved = P13TweaksDB.mapDrawSaved and P13TweaksDB.mapDrawSaved[CharKey()]
    if not saved then return end
    for _, sv in ipairs(saved) do
        local pts = {}
        for u, v in tostring(sv.pts):gmatch("([%d%.%-]+),([%d%.%-]+)") do pts[#pts + 1] = { tonumber(u), tonumber(v) } end
        if #pts >= 2 and sv.map and type(sv.hex) == "string" and #sv.hex == 6 then
            -- how old the line is now: its age when saved plus the real time since (for the fade option)
            local elapsed = (sv.age or 0) + math.max(0, time() - (sv.ts or time()))
            table.insert(strokes, { owner = Me(), id = sv.id or 0, map = sv.map, color = ColorFromHex(sv.hex), pts = pts,
                t = GetTime() - elapsed, th = sv.th })
            nextId = math.max(nextId, sv.id or 0)   -- new lines carry on from the highest number (teammates match lines by it)
        end
    end
    Changed()
end

ns:RegisterOption({
    key = "mapDrawKeep",
    type = "toggle",
    label = "Keep my map drawings through /reload and logout",
    tooltip = "Your lines on the map are saved when you reload or log out and come back when you log in again (per character). Your group's lines come back when their addons send them again. Clear mine removes them for good.",
    default = true,
    onChange = function(on)
        if not on and P13TweaksDB.mapDrawSaved then P13TweaksDB.mapDrawSaved[CharKey()] = nil end
    end,
})

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
elseif RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(PREFIX)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("MODIFIER_STATE_CHANGED")
events:RegisterEvent("PLAYER_LOGOUT")   -- (also fires on /reload)
events:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "PLAYER_LOGOUT" then
        SaveStrokes()
    elseif event == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 and a4 then OnMessage(a2, a4) end
    elseif event == "MODIFIER_STATE_CHANGED" then
        shiftHeld = IsShiftKeyDown() and WorldMapFrame and WorldMapFrame:IsShown() and true or false
        altHeld = ns:Get("mapDrawErase") and IsAltKeyDown() and WorldMapFrame and WorldMapFrame:IsShown() and true or false
        RefreshCatcher()
    elseif event == "GROUP_ROSTER_UPDATE" then
        Later("roster", 1, OnRoster)
    else   -- PLAYER_LOGIN
        RestoreStrokes()
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        if not (sc and sc.Child and sc.GetCanvasScale) then return end

        layer = CreateFrame("Frame", nil, sc.Child)
        layer:SetPoint("TOPLEFT", sc.Child, "TOPLEFT")
        -- High enough to sit above the map's own picture layers (a lower level was hidden behind the map
        -- and only showed in the black border). Lines don't take the mouse, so being on top is harmless.
        layer:SetFrameLevel(sc.Child:GetFrameLevel() + 25)

        -- Over the map while drawing, to catch the mouse. Right-click passes through where the game allows.
        catcher = CreateFrame("Frame", nil, sc)
        catcher:SetAllPoints(sc)
        catcher:SetFrameLevel(sc:GetFrameLevel() + 90)   -- under the button row (+100)
        -- while Shift is held the catcher is up: Shift + wheel sets the line thickness instead of zooming
        catcher:EnableMouseWheel(true)
        -- Shift + wheel: line thickness. Alt (alone) + wheel: eraser size.
        catcher:SetScript("OnMouseWheel", function(_, delta)
            if altHeld and not shiftHeld then ns.EraserWheel(delta) else ns.DrawBrushWheel(delta) end
        end)
        catcher:Hide()
        RefreshCatcher()   -- sets what right-click does while the catcher is on
        -- (Alt alone is the eraser: it works from the eraser's own update, so a click must not start a line)
        catcher:SetScript("OnMouseDown", function(_, button)
            if button == "LeftButton" and not (altHeld and not shiftHeld) then StartStroke() end
        end)
        SetupEraser(sc)
        catcher:SetScript("OnMouseUp", function(_, button) if button == "LeftButton" then EndStroke() end end)
        catcher:SetScript("OnHide", EndStroke)

        undoBtn = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
        undoBtn:SetSize(56, 22)
        undoBtn:SetText("Undo")
        undoBtn:SetFrameLevel(sc:GetFrameLevel() + 100)
        undoBtn:SetScript("OnClick", Undo)
        undoBtn:Hide()
        ns:AddMapButton(undoBtn, 31)

        clearBtn = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
        clearBtn:SetSize(80, 22)
        clearBtn:SetText("Clear mine")
        clearBtn:SetFrameLevel(sc:GetFrameLevel() + 100)
        clearBtn:SetScript("OnClick", ClearMine)
        clearBtn:Hide()
        ns:AddMapButton(clearBtn, 32)

        clearAllBtn = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
        clearAllBtn:SetSize(72, 22)
        clearAllBtn:SetText("Clear all")
        clearAllBtn:SetFrameLevel(sc:GetFrameLevel() + 100)
        clearAllBtn:SetScript("OnClick", function()
            ClearAll()
            ns:Print("Cleared every map drawing, for everyone in your group.")
        end)
        clearAllBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:SetText("Clear all drawings")
            GameTooltip:AddLine("Removes every line on the map, whoever drew it, for everyone in the group.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        clearAllBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        clearAllBtn:Hide()
        ns:AddMapButton(clearAllBtn, 33)

        local dbg = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        dbg:SetPoint("BOTTOM", sc, "BOTTOM", 0, 6)
        local dbgShown
        local poll = CreateFrame("Frame", nil, WorldMapFrame)
        poll:SetScript("OnUpdate", function()
            Redraw(false)
            local t = ns.SheetDraw.debugText() or ""
            if t ~= dbgShown then dbgShown = t; dbg:SetText(t) end
        end)
        poll:SetScript("OnShow", function() Redraw(true) end)
        WorldMapFrame:HookScript("OnHide", function() shiftHeld = false; altHeld = false; FinishErase(); SetDrawing(false) end)

        C_Timer.NewTicker(15, Prune)
    end
end)

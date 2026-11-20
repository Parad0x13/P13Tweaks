-- P13Tweaks feature: draw on the world map and share it with your group.
-- Hold Shift and drag with the left mouse button on the world map to draw a line (while Shift is held,
-- dragging draws instead of panning; right-click still goes back, the wheel still zooms). Undo / Clear mine
-- buttons appear in the map's button row while you have lines.
-- Each finished stroke is sent to the group over the hidden addon channel; teammates who also run
-- P13Tweaks see it on their own map, in the sender's class colour. Lines are stored as positions on the
-- map picture (0..1), so they stay put when you zoom or pan. Lines can fade after a few minutes (an option, off by default).
--
-- Messages (prefix "P13M", fields split by "^"):
--   S^<mapID>^<strokeID>^<part>^<parts>^<RRGGBB>^<points>   one stroke, in pieces of <= 50 points;
--                      each point = 4 characters (two 12-bit numbers, x and y, as base-64 digits)
--   U^<strokeID>       the sender undid that stroke
--   X                  the sender cleared all their lines
--   A                  the sender cleared EVERY line (everyone's) - receivers clear all of theirs too
local ADDON_NAME, ns = ...

local PREFIX = "P13M"
local MAX_MSG = 250
local PTS_PER_MSG = 50          -- 50 points * 4 characters + the header stays under 255 bytes
local BURST, REFILL = 4, 1.5    -- gentle: the quest sharing uses the same game limit
local MIN_STEP = 0.005          -- drawing: ignore points closer than this (fraction of the map)
local MAX_POINTS = 300          -- per stroke
local MAX_STROKES = 80          -- kept per player
local FADE_SECONDS = 30         -- last seconds of a line's life are a fade-out
local THICKNESS = 3

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

local function EncodePoints(pts, from, to)
    local t = {}
    for i = from, to do
        t[#t + 1] = Enc(pts[i][1] * 4095) .. Enc(pts[i][2] * 4095)
    end
    return table.concat(t)
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

local function HexColor(c) return ("%02x%02x%02x"):format(c[1] * 255 + 0.5, c[2] * 255 + 0.5, c[3] * 255 + 0.5) end
local function ColorFromHex(h)
    return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end

local function MyColor()
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

local function Pump()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - lastRefill) / REFILL)
    lastRefill = now
    local ch = Channel()
    if not ch then wipe(queue) end
    while #queue > 0 and tokens >= 1 do
        pcall(SendRaw, PREFIX, table.remove(queue, 1), ch)
        tokens = tokens - 1
    end
    if #queue == 0 and ticker then ticker:Cancel(); ticker = nil end
end

local function Send(msg)
    if not Channel() then return end
    table.insert(queue, msg)
    Pump()
    if #queue > 0 and not ticker then ticker = C_Timer.NewTicker(0.4, Pump) end
end

local function SendStroke(s)
    if not Channel() then return end
    local parts = math.ceil(#s.pts / PTS_PER_MSG)
    for part = 1, parts do
        local from = (part - 1) * PTS_PER_MSG + 1
        local to = math.min(#s.pts, part * PTS_PER_MSG)
        Send(("S^%d^%d^%d^%d^%s^%s"):format(s.map, s.id, part, parts, HexColor(s.color), EncodePoints(s.pts, from, to)))
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

local function OnMessage(msg, sender)
    if not On() then return end
    local who = ShortName(sender)
    if who == Me() then return end
    local kind = msg:sub(1, 1)
    if kind == "S" then
        local map, id, part, parts, hex, pts = msg:match("^S%^(%d+)%^(%d+)%^(%d+)%^(%d+)%^(%x%x%x%x%x%x)%^(.*)$")
        if not map then return end
        part, parts = tonumber(part), tonumber(parts)
        if part < 1 or parts < 1 or part > parts or parts > math.ceil(MAX_POINTS / PTS_PER_MSG) then return end
        local decoded = DecodePoints(pts)
        if not decoded then return end
        local key = who .. ":" .. id
        local p = partial[key]
        if not p or p.parts ~= parts then
            p = { parts = parts, got = {}, map = tonumber(map), id = tonumber(id), hex = hex }
            partial[key] = p
        end
        p.got[part] = decoded
        local have = 0
        for _ in pairs(p.got) do have = have + 1 end
        if have == parts then
            partial[key] = nil
            local all = {}
            for i = 1, parts do for _, pt in ipairs(p.got[i]) do all[#all + 1] = pt end end
            -- a re-sent stroke replaces the old copy
            RemoveWhere(function(s) return s.owner == who and s.id == p.id end)
            AddStroke({ owner = who, id = p.id, map = p.map, color = ColorFromHex(p.hex), pts = all, t = GetTime() })
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

local function Redraw(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (layer and child) then return end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    local sig = ("%d:%d:%.5f:%.0f:%d:%s"):format(version, mapID, scale, W, math.floor(GetTime() / 3), tostring(On()))
    if sig == lastSig and not force then return end
    lastSig = sig

    for i = 1, linesUsed do linePool[i]:Hide() end
    linesUsed = 0
    if not On() then return end

    RaiseLayer(child, force)
    layer:SetScale(1 / scale)
    layer:SetSize(W * scale, H * scale)
    local sx, sy = W * scale, H * scale
    local minutes = FadeMinutes()
    local now = GetTime()
    for _, s in ipairs(strokes) do
        if s.map == mapID and #s.pts >= 2 then
            local alpha = 0.9
            if minutes then
                local left = minutes * 60 - (now - s.t)
                if left < FADE_SECONDS then alpha = 0.9 * math.max(0.1, left / FADE_SECONDS) end
            end
            for i = 2, #s.pts do
                if linesUsed >= 3000 then break end
                local a, b = s.pts[i - 1], s.pts[i]
                local l = GetLine()
                l:SetThickness(THICKNESS)
                l:SetColorTexture(s.color[1], s.color[2], s.color[3], alpha)
                l:SetStartPoint("TOPLEFT", layer, a[1] * sx, -a[2] * sy)
                l:SetEndPoint("TOPLEFT", layer, b[1] * sx, -b[2] * sy)
            end
        end
    end
end

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
local function RefreshCatcher()
    if not catcher then return end
    local active = On() and (drawing or shiftHeld or current ~= nil) and true or false
    if catcher:IsShown() ~= active then catcher:SetShown(active) end
    catcher:EnableMouse(active)
end

local function EndStroke()
    if not current then return end
    local s = current
    current = nil
    catcher:SetScript("OnUpdate", nil)
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

local function StartStroke()
    local mapID = WorldMapFrame:GetMapID()
    local u, v = CursorOnMap()
    if not (mapID and u) then return end
    current = { owner = Me(), id = 0, map = mapID, color = MyColor(), pts = { { u, v } }, t = GetTime() }
    table.insert(strokes, current)
    Changed()
    catcher:SetScript("OnUpdate", function()
        if not current then return end
        local cu, cv = CursorOnMap()
        if not cu then return end
        local last = current.pts[#current.pts]
        if (cu - last[1]) ^ 2 + (cv - last[2]) ^ 2 >= MIN_STEP ^ 2 and #current.pts < MAX_POINTS then
            current.pts[#current.pts + 1] = { cu, cv }
            Changed()
        end
    end)
end

local function SetDrawing(on)
    on = on and On() and true or false
    if not on then EndStroke() end
    drawing = on
    RefreshCatcher()
    UpdateButtons()
end

---------------------------------------------------------------------------
-- Options and commands
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "mapDraw",
    type = "toggle",
    label = "Draw on the map and share it with my group",
    tooltip = "Hold Shift and drag with the left mouse button on the world map to draw a line. Teammates who also have P13Tweaks see your lines on their map (and you see theirs), each in the sender's class colour. Undo and Clear mine buttons appear in the map's button row while you have lines. While Shift is held, dragging draws instead of panning the map.",
    default = true,
    onChange = function(on)
        if not on then SetDrawing(false) end
        RefreshCatcher()
        Changed()
    end,
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
events:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 and a4 then OnMessage(a2, a4) end
    elseif event == "MODIFIER_STATE_CHANGED" then
        shiftHeld = IsShiftKeyDown() and WorldMapFrame and WorldMapFrame:IsShown() and true or false
        RefreshCatcher()
    elseif event == "GROUP_ROSTER_UPDATE" then
        Later("roster", 1, OnRoster)
    else   -- PLAYER_LOGIN
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
        catcher:Hide()
        if catcher.SetPassThroughButtons then pcall(catcher.SetPassThroughButtons, catcher, "RightButton") end
        catcher:SetScript("OnMouseDown", function(_, button) if button == "LeftButton" then StartStroke() end end)
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

        local poll = CreateFrame("Frame", nil, WorldMapFrame)
        poll:SetScript("OnUpdate", function() Redraw(false) end)
        poll:SetScript("OnShow", function() Redraw(true) end)
        WorldMapFrame:HookScript("OnHide", function() shiftHeld = false; SetDrawing(false) end)

        C_Timer.NewTicker(15, Prune)
    end
end)

-- P13Tweaks feature: dungeon quest pins.
-- Pick a dungeon (the Dungeon button on the world map, or /p13 -> Map -> Dungeon quests) and a "!" pin goes on the
-- map wherever you pick up one of its quests. A dungeon quest is one QuestieDB files under that dungeon, or one whose
-- creatures / item drops / objects to use are inside it (so e.g. Westfall's "The Defias Brotherhood" counts for the
-- Deadmines). Quests you've done or already have are left out, as are ones your race / class can't take. When a quest
-- needs earlier quests first, the pin goes on the first one of that chain you can pick up. Greyed pins: you can't take
-- it yet (hover for why, e.g. level). Hover a pin for the quests; click it for a waypoint.
-- Needs QuestieDB. Giver points, prerequisites and blockers come from QuestWhere.lua.
local ADDON_NAME, ns = ...

local ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local DISC = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"   -- a round white disc, tinted for the pin's backing
local SIZE = 30

-- area ids (QuestieDB / AreaTable) of each dungeon and its sub-areas, with the usual level range
local DUNGEONS = {
    { key = "RFC",  name = "Ragefire Chasm",       short = "Ragefire",   lvl = "13-18", areas = { 2437 } },
    { key = "WC",   name = "Wailing Caverns",      short = "Wailing C.", lvl = "17-24", areas = { 718, 6511 } },
    { key = "DM",   name = "The Deadmines",        short = "Deadmines",  lvl = "17-26", areas = { 1581, 10029 } },
    { key = "SFK",  name = "Shadowfang Keep",      short = "Shadowfang", lvl = "22-30", areas = { 209, 10014, 10015, 10016, 10017, 10018, 10019 } },
    { key = "BFD",  name = "Blackfathom Deeps",    short = "Blackfathom", lvl = "24-32", areas = { 719, 10020, 10021 } },
    { key = "STOCK", name = "The Stockade",        short = "Stockade",   lvl = "24-32", areas = { 717 } },
    { key = "GNOMER", name = "Gnomeregan",         short = "Gnomeregan", lvl = "29-38", areas = { 721, 10030, 10031, 10032 } },
    { key = "RFK",  name = "Razorfen Kraul",       short = "Kraul",      lvl = "29-38", areas = { 491 } },
    { key = "SM",   name = "Scarlet Monastery",    short = "Scarlet M.", lvl = "34-45", areas = { 796, 10008, 10009, 10010 } },
    { key = "RFD",  name = "Razorfen Downs",       short = "Downs",      lvl = "37-46", areas = { 722 } },
    { key = "ULDA", name = "Uldaman",              short = "Uldaman",    lvl = "41-51", areas = { 1337, 10033 } },
    { key = "ZF",   name = "Zul'Farrak",           short = "Zul'Farrak", lvl = "44-54", areas = { 1176 } },
    { key = "MARA", name = "Maraudon",             short = "Maraudon",   lvl = "46-55", areas = { 2100, 10000 } },
    { key = "ST",   name = "Sunken Temple",        short = "Sunken T.",  lvl = "50-56", areas = { 1417, 1477 } },
    { key = "BRD",  name = "Blackrock Depths",     short = "BRD",        lvl = "52-60", areas = { 1584, 1585 } },
    { key = "BRS",  name = "Blackrock Spire",      short = "BRS",        lvl = "55-60", areas = { 1583, 10003, 10004, 10005, 10006, 10007 } },
    { key = "DIRE", name = "Dire Maul",            short = "Dire Maul",  lvl = "55-60", areas = { 2557, 10022, 10023, 10024, 10025, 10026, 10027 } },
    { key = "SCHOLO", name = "Scholomance",        short = "Scholo",     lvl = "58-60", areas = { 2057, 10011, 10012, 10013 } },
    { key = "STRAT", name = "Stratholme",          short = "Strat",      lvl = "58-60", areas = { 2017, 10001 } },
    { key = "ZG",   name = "Zul'Gurub",            short = "Zul'Gurub",  lvl = "raid", raid = true, areas = { 1977 } },
    { key = "ONY",  name = "Onyxia's Lair",        short = "Onyxia",     lvl = "raid", raid = true, areas = { 2159 } },
    { key = "MC",   name = "Molten Core",          short = "Molten Core", lvl = "raid", raid = true, areas = { 2717 } },
    { key = "BWL",  name = "Blackwing Lair",       short = "BWL",        lvl = "raid", raid = true, areas = { 2677 } },
    { key = "AQ20", name = "Ruins of Ahn'Qiraj",   short = "AQ20",       lvl = "raid", raid = true, areas = { 3429 } },
    { key = "AQ40", name = "Temple of Ahn'Qiraj",  short = "AQ40",       lvl = "raid", raid = true, areas = { 3428, 10040, 10041 } },
    { key = "NAXX", name = "Naxxramas",            short = "Naxx",       lvl = "raid", raid = true, areas = { 3456, 10062, 10063, 10064, 10065, 10066 } },
}
local byKey = {}
for _, d in ipairs(DUNGEONS) do byKey[d.key] = d end

local function Lib()
    local lib = _G.LibQuestieDB
    if lib and lib.Quest and lib.Quest.Get and lib.Quest.GetAllIds and lib.Npc and lib.Npc.Get then return lib end
end

local function Get(db, id, field)
    if not (db and db.Get) then return end
    local ok, v = pcall(db.Get, id, field)
    if ok then return v end
end

local function On() return ns:Get("dungeonQuests") end
local function Chosen() return On() and byKey[ns:Get("dungeonQuestsWhich") or ""] or nil end

local layer, button, picker
local pool, used = {}, 0
local lastSig
local Redraw

---------------------------------------------------------------------------
-- Which quests belong to a dungeon (one pass over QuestieDB, a few hundred quests per frame)
---------------------------------------------------------------------------

local questsOf = {}      -- dungeon key -> { questIDs }; filled for every dungeon by one scan
local scanning           -- true while the scan runs
local scanDone = {}      -- functions to call once the scan has finished
local PER_FRAME = 300

local keyOfArea = {}     -- area id -> dungeon key
for _, d in ipairs(DUNGEONS) do for _, a in ipairs(d.areas) do keyOfArea[a] = d.key end end

-- One pass over QuestieDB sorts every quest into the dungeons it belongs to (all dungeons at once, so the
-- picker can show how many quests each one has).
local function StartScan(onDone)
    if onDone then
        if questsOf.ready then onDone(); return end
        scanDone[#scanDone + 1] = onDone
    end
    if questsOf.ready or scanning then return end
    local lib = Lib()
    if not lib then return end
    local ok, ids = pcall(lib.Quest.GetAllIds)
    if not ok or type(ids) ~= "table" then return end
    local npcIn, objIn = {}, {}   -- cache: which dungeons does this creature / object spawn in? (key -> true, or false)
    local function SpawnsIn(db, cache, id)
        if type(id) ~= "number" then return false end
        local c = cache[id]
        if c ~= nil then return c end
        c = false
        local spawns = Get(db, id, "spawns")
        if type(spawns) == "table" then
            for area in pairs(spawns) do
                local k = keyOfArea[area]
                if k then c = c or {}; c[k] = true end
            end
        end
        cache[id] = c
        return c
    end
    local function Add(set, keys) if keys then for k in pairs(keys) do set[k] = true end end end
    local function Belongs(qid)   -- set of dungeon keys
        local set = {}
        local zone = Get(lib.Quest, qid, "zoneOrSort")
        if type(zone) == "number" and keyOfArea[zone] then set[keyOfArea[zone]] = true end
        local o = Get(lib.Quest, qid, "objectives")
        if type(o) ~= "table" then return set end
        for _, e in ipairs(type(o[1]) == "table" and o[1] or {}) do Add(set, SpawnsIn(lib.Npc, npcIn, e[1])) end
        if lib.Object then
            for _, e in ipairs(type(o[2]) == "table" and o[2] or {}) do Add(set, SpawnsIn(lib.Object, objIn, e[1])) end
        end
        for _, e in ipairs(type(o[3]) == "table" and o[3] or {}) do
            local drops = lib.Item and type(e[1]) == "number" and Get(lib.Item, e[1], "npcDrops")
            if type(drops) == "table" then
                local inside, total = {}, 0
                for _, n in ipairs(drops) do
                    total = total + 1
                    local keys = SpawnsIn(lib.Npc, npcIn, n)
                    if keys then for k in pairs(keys) do inside[k] = (inside[k] or 0) + 1 end end
                end
                -- the item mostly drops in there (not some common item that one dungeon mob also drops)
                for k, n in pairs(inside) do if n * 2 >= total then set[k] = true end end
            end
        end
        for _, e in ipairs(type(o[5]) == "table" and o[5] or {}) do Add(set, SpawnsIn(lib.Npc, npcIn, e[2])) end
        return set
    end
    local found = {}
    for _, d in ipairs(DUNGEONS) do found[d.key] = {} end
    scanning = true
    local i = 1
    local function Step()
        local last = math.min(#ids, i + PER_FRAME - 1)
        for k = i, last do
            local qid = ids[k]
            for key in pairs(Belongs(qid)) do local f = found[key]; f[#f + 1] = qid end
        end
        i = last + 1
        if i <= #ids then C_Timer.After(0, Step); return end
        for key, list in pairs(found) do questsOf[key] = list end
        questsOf.ready = true
        scanning = nil
        lastSig = nil
        local waiting = scanDone
        scanDone = {}
        for _, f in ipairs(waiting) do pcall(f) end
        if Redraw then Redraw(true) end
    end
    Step()
end

---------------------------------------------------------------------------
-- What to pin: for each dungeon quest you can still do, where to pick up it (or the first quest leading to it)
---------------------------------------------------------------------------

local function PermanentlyBlocked(lib, qid)
    local _, _, raceId = UnitRace("player")
    local _, _, classId = UnitClass("player")
    local races = Get(lib.Quest, qid, "requiredRaces")
    if type(races) == "number" and races > 0 and raceId and raceId <= 31
        and bit.band(races, bit.lshift(1, raceId - 1)) == 0 then return true end
    local classes = Get(lib.Quest, qid, "requiredClasses")
    if type(classes) == "number" and classes > 0 and classId and classId <= 31
        and bit.band(classes, bit.lshift(1, classId - 1)) == 0 then return true end
    local excl = Get(lib.Quest, qid, "exclusiveTo")
    if type(excl) == "table" then
        for _, other in ipairs(excl) do
            if type(other) == "number" and ((ns.QuestCompleted and ns.QuestCompleted(other)) or (ns.HasQuest and ns.HasQuest(other))) then
                return true
            end
        end
    end
    -- too high a level for it (a quest only for low levels)
    local maxLevel = Get(lib.Quest, qid, "requiredMaxLevel")
    if type(maxLevel) == "number" and maxLevel > 0 and UnitLevel("player") > maxLevel then return true end
    return false
end

local cacheOf = {}   -- dungeon key -> { entries, counts, at }; wipe() it to work everything out again

-- { qid, title, stepId, stepTitle, reasons } per quest to pin, and
-- counts = { done, log, notYou, total (still to pick up), now (of those, takeable now) }. nil, nil until the scan is done.
local function Entries(d)
    d = d or Chosen()
    if not d then return {}, nil end
    local c = cacheOf[d.key]
    if c and GetTime() - c.at < 3 then return c.entries, c.counts end
    local lib = Lib()
    local list = questsOf[d.key]
    if not (lib and list) then StartScan(); return {}, nil end
    local entries = {}
    local counts = { done = 0, log = 0, total = 0, now = 0, notYou = 0 }
    cacheOf[d.key] = { entries = entries, counts = counts, at = GetTime() }
    local seenStep = {}
    for _, qid in ipairs(list) do
        if ns.QuestCompleted and ns.QuestCompleted(qid) then
            counts.done = counts.done + 1
        elseif ns.HasQuest and ns.HasQuest(qid) then
            counts.log = counts.log + 1
        elseif PermanentlyBlocked(lib, qid) then
            counts.notYou = counts.notYou + 1
        else
            local step = ns.QuestNextStep and ns.QuestNextStep(qid) or { id = qid, kind = "start" }
            if step and step.kind == "start" and not PermanentlyBlocked(lib, step.id) then
                counts.total = counts.total + 1
                local reasons = (ns.WhyCantTake and ns.WhyCantTake(step.id)) or {}
                if #reasons == 0 then counts.now = counts.now + 1 end
                local e = {
                    qid = qid,
                    title = ns.QuestName and ns.QuestName(qid) or ("Quest " .. qid),
                    stepId = step.id,
                    stepTitle = step.id ~= qid and (ns.QuestName and ns.QuestName(step.id) or ("Quest " .. step.id)) or nil,
                    reasons = reasons,
                }
                -- several dungeon quests reached through the same lead-up quest: one entry for it, listing them all
                local same = seenStep[step.id]
                if same then
                    same.also = same.also or {}
                    same.also[#same.also + 1] = e.title
                else
                    seenStep[step.id] = e
                    entries[#entries + 1] = e
                end
            elseif step and step.kind == "log" then
                counts.log = counts.log + 1   -- its lead-up quest is in your log already
            end
        end
    end
    return entries, counts
end

---------------------------------------------------------------------------
-- Pins
---------------------------------------------------------------------------

local convCache = {}
local function PointsOn(stepId, mapID)
    local key = stepId .. ":" .. mapID
    if convCache[key] then return convCache[key] end
    local out = {}
    local pts = ns.QuestGiverPoints and ns.QuestGiverPoints(stepId) or {}
    for _, p in ipairs(pts) do
        local u, v
        if p.uiMap == mapID then
            u, v = p.x / 100, p.y / 100
        elseif C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D then
            local cont, wpos = C_Map.GetWorldPosFromMapPos(p.uiMap, CreateVector2D(p.x / 100, p.y / 100))
            if cont and wpos then
                local _, mpos = C_Map.GetMapPosFromWorldPos(cont, wpos, mapID)
                if mpos then u, v = mpos:GetXY() end
            end
        end
        if u and v and u >= 0 and u <= 1 and v >= 0 and v <= 1 then out[#out + 1] = { u = u, v = v, p = p } end
    end
    convCache[key] = out
    return out
end

-- Keep the pin layer above the map's own picture layers and pins (as MapQuestHints.lua does).
local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local lastRaise = 0
local function RaiseLayer(child)
    if GetTime() - lastRaise < 1 then return end
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
        if k ~= layer and k:GetFrameStrata() == topName then maxLevel = math.max(maxLevel, k:GetFrameLevel()) end
    end
    local want = math.min(9999, maxLevel + 1)
    if layer:GetFrameLevel() ~= want then layer:SetFrameLevel(want) end
end

local function ZoneName(uiMap)
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(uiMap)
    return info and info.name or ("map " .. uiMap)
end

local function ShowTooltip(self)
    local g = self.group
    if not g then return end
    local d = Chosen()
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(g[1].point.name or "Quest giver", 1, 1, 1)
    if d then GameTooltip:AddLine(d.name .. " quests", 0.6, 0.8, 1) end
    for i, x in ipairs(g) do
        if i > 6 then GameTooltip:AddLine(("...and %d more"):format(#g - 6), 0.7, 0.7, 0.7); break end
        local e = x.entry
        if e.stepTitle then
            GameTooltip:AddLine(e.stepTitle, 1, 0.82, 0)
            GameTooltip:AddLine("   leads to: " .. e.title .. (e.also and (", " .. table.concat(e.also, ", ")) or ""), 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine(e.title, 1, 0.82, 0)
            if e.also then GameTooltip:AddLine("   also leads to: " .. table.concat(e.also, ", "), 0.8, 0.8, 0.8, true) end
        end
        if #e.reasons > 0 then GameTooltip:AddLine("   can't take it yet: " .. e.reasons[1], 1, 0.4, 0.3, true) end
    end
    GameTooltip:AddLine("Click to set a waypoint here", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function SetWaypoint(self)
    local p = self.group and self.group[1] and self.group[1].point
    if not p then return end
    local placed = false
    if C_Map.SetUserWaypoint and UiMapPoint and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(p.uiMap)) then
        placed = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(p.uiMap, p.x / 100, p.y / 100))
        if placed and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
    ns:Print((placed and "Waypoint set: " or "Quest giver: ") .. ("%s - %s %.1f, %.1f"):format(p.name or "quest giver", ZoneName(p.uiMap), p.x, p.y))
end

-- A pin: the "!" on a dark disc with a gold ring, and a gold glow behind that slowly pulses so it catches the eye.
local function Icon()
    used = used + 1
    local b = pool[used]
    if not b then
        b = CreateFrame("Button", nil, layer)
        b:SetSize(SIZE, SIZE)
        b.glow = b:CreateTexture(nil, "BACKGROUND", nil, -2)
        b.glow:SetPoint("CENTER")
        b.glow:SetSize(SIZE * 1.9, SIZE * 1.9)
        b.glow:SetTexture(DISC)
        b.glow:SetBlendMode("ADD")
        b.glow:SetVertexColor(1, 0.75, 0.1, 0.55)
        b.ring = b:CreateTexture(nil, "BACKGROUND", nil, -1)
        b.ring:SetPoint("CENTER")
        b.ring:SetSize(SIZE, SIZE)
        b.ring:SetTexture(DISC)
        b.disc = b:CreateTexture(nil, "BACKGROUND", nil, 0)
        b.disc:SetPoint("CENTER")
        b.disc:SetSize(SIZE - 4, SIZE - 4)
        b.disc:SetTexture(DISC)
        b.disc:SetVertexColor(0, 0, 0, 0.85)
        b.tex = b:CreateTexture(nil, "OVERLAY")
        b.tex:SetPoint("CENTER")
        b.tex:SetSize(SIZE - 4, SIZE - 4)
        b.tex:SetTexture(ICON)
        b.pulse = b.glow:CreateAnimationGroup()
        b.pulse:SetLooping("BOUNCE")
        local a = b.pulse:CreateAnimation("Alpha")
        a:SetFromAlpha(1)
        a:SetToAlpha(0.2)
        a:SetDuration(0.8)
        a:SetSmoothing("IN_OUT")
        b:SetScript("OnEnter", ShowTooltip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", SetWaypoint)
        pool[used] = b
    end
    b:Show()
    return b
end

Redraw = function(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (layer and child) then return end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    local d = Chosen()
    local st = lastSig
    if not st then st = {}; lastSig = st end
    if ns.SigSame(st, mapID, math.floor(scale * 1e5), math.floor(W), math.floor(GetTime() / 3),
        d and d.key or "") and not force then return end

    for i = 1, used do pool[i]:Hide() end
    used = 0
    if not d then return end

    RaiseLayer(child)
    layer:SetScale(1 / scale)
    layer:SetSize(W * scale, H * scale)
    local sx, sy = W * scale, H * scale

    local groups, order = {}, {}
    for _, e in ipairs(Entries()) do
        for _, pt in ipairs(PointsOn(e.stepId, mapID)) do
            local key = math.floor(pt.u * 150) .. "_" .. math.floor(pt.v * 150)
            local g = groups[key]
            if not g then g = { u = pt.u, v = pt.v }; groups[key] = g; order[#order + 1] = g end
            g[#g + 1] = { entry = e, point = pt.p }
        end
    end
    for _, g in ipairs(order) do
        local b = Icon()
        b.group = g
        b:ClearAllPoints()
        b:SetPoint("CENTER", layer, "TOPLEFT", g.u * sx, -g.v * sy)
        local anyTake = false
        for _, x in ipairs(g) do if #x.entry.reasons == 0 then anyTake = true end end
        b.tex:SetDesaturated(not anyTake)
        if anyTake then
            b.tex:SetVertexColor(1, 1, 1, 1)
            b.ring:SetVertexColor(1, 0.82, 0.1, 1)
            b.glow:Show()
            if not b.pulse:IsPlaying() then b.pulse:Play() end
        else
            b.tex:SetVertexColor(0.6, 0.6, 0.6, 0.8)
            b.ring:SetVertexColor(0.5, 0.5, 0.5, 0.8)
            b.pulse:Stop()
            b.glow:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Picking a dungeon
---------------------------------------------------------------------------

local function UpdateButton()
    if not button then return end
    local d = Chosen()
    local text = d and d.short or "Dungeon"
    if d then
        local _, counts = Entries(d)
        if counts then text = ("%s |cffffd100%d|r"):format(d.short, counts.total) end
    end
    button:SetText(text)
    button:SetShown(On() and true or false)
end

-- Say in chat how many pins there are, once the dungeon's quests are known.
local function Report(d)
    if Chosen() ~= d or not questsOf[d.key] then return end
    cacheOf[d.key] = nil
    local _, counts = Entries(d)
    if not counts then return end
    UpdateButton()
    local extra = {}
    if counts.total > counts.now then extra[#extra + 1] = (counts.total - counts.now) .. " not yet (greyed)" end
    if counts.done > 0 then extra[#extra + 1] = counts.done .. " done" end
    if counts.log > 0 then extra[#extra + 1] = counts.log .. " in your log" end
    if counts.notYou > 0 then extra[#extra + 1] = counts.notYou .. " not for you" end
    ns:Print(("%s: %d quest%s to pick up%s."):format(d.name, counts.total, counts.total == 1 and "" or "s",
        #extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or ""))
end

local function Choose(key)
    ns:Set("dungeonQuestsWhich", key)
    lastSig = nil
    local d = byKey[key or ""]
    if d then
        if not Lib() then ns:Print("Dungeon quest pins need QuestieDB.") return end
        StartScan(function() Report(d) end)
    end
    UpdateButton()
    if picker then picker:Hide() end
    Redraw(true)
end

local function BuildPicker()
    picker = CreateFrame("Frame", "P13TweaksDungeonPicker", UIParent, "BackdropTemplate")
    picker:SetFrameStrata("DIALOG")
    picker:SetClampedToScreen(true)
    picker:EnableMouse(true)
    if picker.SetBackdrop then
        picker:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        picker:SetBackdropColor(0, 0, 0, 0.92)
    end
    local ROW, COLW = 18, 225
    local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Dungeon quests - pick a dungeon")
    local close = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    local function Row(col, i, text, key)
        local b = CreateFrame("Button", nil, picker)
        b:SetSize(COLW - 10, ROW)
        b:SetPoint("TOPLEFT", 10 + (col - 1) * COLW, -28 - (i - 1) * ROW)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT")
        b.text:SetText(text)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetScript("OnClick", function() Choose(key) end)
        b.key = key
        if key then
            -- how many of its quests you can still pick up
            b.count = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            b.count:SetPoint("RIGHT", -4, 0)
            b:SetScript("OnEnter", function(self)
                if not self.counts then return end
                local c = self.counts
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(byKey[key].name)
                GameTooltip:AddLine(("%d quest%s still to pick up"):format(c.total, c.total == 1 and "" or "s"), 1, 1, 1)
                if c.now > 0 then GameTooltip:AddLine(c.now .. " you can take now", 0.3, 1, 0.3) end
                if c.total > c.now then GameTooltip:AddLine((c.total - c.now) .. " you can't take yet (level or an earlier quest)", 0.7, 0.7, 0.7) end
                if c.log > 0 then GameTooltip:AddLine(c.log .. " in your log", 1, 0.82, 0) end
                if c.done > 0 then GameTooltip:AddLine(c.done .. " done", 0.6, 0.6, 0.6) end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return b
    end
    picker.rows = {}
    local left, right = 0, 0
    for _, d in ipairs(DUNGEONS) do
        local text = ("%s  |cff999999%s|r"):format(d.name, d.raid and "raid" or d.lvl)
        if d.raid then right = right + 1; picker.rows[#picker.rows + 1] = Row(2, right, text, d.key)
        else left = left + 1; picker.rows[#picker.rows + 1] = Row(1, left, text, d.key) end
    end
    right = right + 2
    picker.rows[#picker.rows + 1] = Row(2, right, "|cffff8080None (remove the pins)|r", false)
    picker:SetSize(COLW * 2 + 10, 40 + math.max(left, right) * ROW)
    local function FillCounts(self)
        for _, r in ipairs(self.rows) do
            if r.count then
                local _, c = Entries(byKey[r.key])
                r.counts = c
                if not c then
                    r.count:SetText("...")
                    r.count:SetTextColor(0.6, 0.6, 0.6)
                elseif c.total == 0 then
                    r.count:SetText("0")
                    r.count:SetTextColor(0.45, 0.45, 0.45)
                elseif c.now > 0 then
                    r.count:SetText(c.total)
                    r.count:SetTextColor(1, 0.82, 0)        -- some you can take now: gold
                else
                    r.count:SetText(c.total)
                    r.count:SetTextColor(0.65, 0.65, 0.65)  -- none takeable yet: grey
                end
            end
        end
    end
    picker:SetScript("OnShow", function(self)
        local cur = ns:Get("dungeonQuestsWhich")
        for _, r in ipairs(self.rows) do
            if r.key and r.key == cur then r.text:SetTextColor(0.3, 1, 0.3) else r.text:SetTextColor(1, 1, 1) end
        end
        FillCounts(self)
        if not questsOf.ready then StartScan(function() if self:IsShown() then FillCounts(self) end end) end
    end)
    -- (not added to UISpecialFrames for Escape: writing into that Blizzard table could spread taint)
    picker:Hide()
end

local function TogglePicker(anchor)
    if not picker then BuildPicker() end
    if picker:IsShown() then picker:Hide(); return end
    picker:ClearAllPoints()
    if anchor then
        picker:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
    else
        picker:SetPoint("CENTER", UIParent, "CENTER")
    end
    picker:Show()
end

---------------------------------------------------------------------------
-- Options and setup
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "dungeonQuests",
    type = "toggleButton",
    label = "Dungeon quest pins on the map",
    buttonText = "Pick...",
    buttonWidth = 70,
    onClick = function() if not On() then ns:Set("dungeonQuests", true); if ns.RefreshOptions then pcall(ns.RefreshOptions, ns) end end; TogglePicker(nil) end,
    tooltip = "Pick a dungeon (Pick... here, or the Dungeon button on the world map) and a ! goes on the map at every place you pick up one of its quests (the list shows how many each dungeon has left for you) - including quests elsewhere that send you into it. If a quest needs earlier quests first, the pin is on the first one you can take. Done quests, ones in your log and ones your race or class can't take are left out; greyed pins you can't take yet (hover for why). Click a pin for a waypoint.\n\nNeeds QuestieDB.",
    default = true,
    onChange = function(v)
        if not v and picker then picker:Hide() end
        UpdateButton()
        lastSig = nil
        Redraw(true)
    end,
})

ns:RegisterCommand("dungeon", "pick a dungeon to pin its quests on the map", function() TogglePicker(nil) end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("QUEST_TURNED_IN")
events:RegisterEvent("QUEST_ACCEPTED")
events:RegisterEvent("QUEST_REMOVED")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:SetScript("OnEvent", function(_, event)
    if event ~= "PLAYER_LOGIN" then
        -- done / in-log / level changed: work the pins out again shortly
        C_Timer.After(0.5, function() wipe(cacheOf); lastSig = nil; UpdateButton() end)
        return
    end
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.Child and sc.GetCanvasScale) then return end

    layer = CreateFrame("Frame", nil, sc.Child)
    layer:SetPoint("TOPLEFT", sc.Child, "TOPLEFT")

    button = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    button:SetSize(112, 22)
    button:SetFrameLevel(sc:GetFrameLevel() + 100)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(self, mb)
        if mb == "RightButton" then Choose(false) else TogglePicker(self) end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("Dungeon quests")
        local d = Chosen()
        GameTooltip:AddLine(d and ("Showing where to pick up " .. d.name .. " quests.") or "Pin where to pick up a dungeon's quests.", 1, 1, 1, true)
        GameTooltip:AddLine("Left-click: pick a dungeon. Right-click: remove the pins.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ns:AddMapButton(button, 37)
    UpdateButton()

    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function() if ns.layersStamp ~= GetTime() then Redraw(false) end end)
    ns.AddMapLayerRefresh(function() Redraw(false) end)
    poll:SetScript("OnShow", function() wipe(cacheOf); UpdateButton(); Redraw(true) end)
    WorldMapFrame:HookScript("OnHide", function() if picker then picker:Hide() end end)
    -- the chosen dungeon's quests are worked out in the background soon after login, so the map is ready
    C_Timer.After(5, function() local d = Chosen(); if d then StartScan(UpdateButton) end end)
end)

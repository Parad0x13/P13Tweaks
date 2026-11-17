-- P13Tweaks feature: see your teammates' quests and progress.
-- Everyone in the group who also runs P13Tweaks sends their quest log (titles + objective progress)
-- over the hidden addon channel. You see it in a window (/p13 quests) and on tooltips of quest mobs
-- and items ("Name: 3/10"). The game doesn't let addons read another player's quest log, so
-- teammates without P13Tweaks can't show up.
--
-- Messages (prefix "P13Q", fields split by "^", objectives by "~"):
--   H^<protocol>       hello: "I'm here" - everyone answers with their full list
--   C                  start of my full list: forget what you had for me
--   Q^<id>^<state>^<title>^<obj>~<obj>...
--                      one quest; state 1 = ready to turn in, -1 = failed, 0 = in progress;
--                      each objective starts with + (done) or - (not done)
--   R^<id>             that quest left my log
--   X                  I turned sharing off: forget me
--   D^<id>             I've already finished that quest (sent only for quests someone in the group
--                      has had, so the window can tell "not started" from "already done")
-- The window (/p13 quests) has two views: by quest (every quest anyone has, with where each player
-- is on it - including players who haven't picked it up) and by player. Clicking one of your own
-- quests shares it with the group through the game's normal quest sharing.
local ADDON_NAME, ns = ...

local PREFIX = "P13Q"
local PROTOCOL = 1             -- bump when the message format changes
local MAX_MSG = 250            -- the game allows 255 bytes per addon message
local BURST, REFILL = 8, 1.1   -- send up to 8 at once, then one every 1.1 s (under the game's limit)


local members = {}    -- name -> { quests = { [id] = { title, state, objs = { {text, done} } } }, protocol, demo }
local myQuests = {}   -- my own quest log, same shape (plus .header)
ns.HasQuest = function(id) return myQuests[id] ~= nil end   -- used by QuestWhere.lua
local lastSent = {}   -- id -> the message we last sent for that quest
local warned = {}     -- name -> true once we've said their P13Tweaks is a different version
local seen = {}       -- id -> title: every quest anyone in the group has had in their log
local sentDone = {}   -- id -> true once I've told the group I finished it
local RefreshWindow   -- set further down
local ReportDone      -- set further down

local function Sharing() return ns:Get("questShare") end

-- Have I already finished this quest (turned it in)?
local function Completed(id)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        return C_QuestLog.IsQuestFlaggedCompleted(id) and true or false
    end
    if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(id) and true or false end
    return false
end
ns.QuestCompleted = Completed   -- used by QuestWhere.lua

-- Runs fn after delay seconds; asking again while it's waiting does nothing (so bursts become one call).
local pending = {}
local function Later(key, delay, fn)
    if pending[key] then return end
    pending[key] = true
    C_Timer.After(delay, function() pending[key] = nil; fn() end)
end

---------------------------------------------------------------------------
-- Reading my own quest log (works on both the old and the newer quest API)
---------------------------------------------------------------------------

local function NumEntries()
    if GetNumQuestLogEntries then return (GetNumQuestLogEntries()) or 0 end
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then return (C_QuestLog.GetNumQuestLogEntries()) or 0 end
    return 0
end

-- title, isHeader, isCollapsed, isComplete, questID
local function Entry(i)
    if GetQuestLogTitle then
        local title, _, _, isHeader, isCollapsed, isComplete, _, questID = GetQuestLogTitle(i)
        return title, isHeader, isCollapsed, isComplete, questID
    elseif C_QuestLog and C_QuestLog.GetInfo then
        local info = C_QuestLog.GetInfo(i)
        if not info then return end
        local done = info.questID and C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
        return info.title, info.isHeader, info.isCollapsed, done and 1 or nil, info.questID
    end
end

local function Objectives(i, questID)
    local objs = {}
    if C_QuestLog and C_QuestLog.GetQuestObjectives and questID then
        local ok, list = pcall(C_QuestLog.GetQuestObjectives, questID)
        if ok and type(list) == "table" and #list > 0 then
            for _, o in ipairs(list) do
                if o.text and o.text ~= "" then table.insert(objs, { o.text, o.finished and true or false }) end
            end
            return objs
        end
    end
    if GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
        for j = 1, (GetNumQuestLeaderBoards(i) or 0) do
            local text, _, finished = GetQuestLogLeaderBoard(j, i)
            if text and text ~= "" then table.insert(objs, { text, finished and true or false }) end
        end
    end
    return objs
end

-- Returns quests (id -> quest) and the set of collapsed header titles.
-- Quests under a collapsed header aren't listed by the game, so we can't see them.
local function Snapshot()
    local quests, collapsed, header = {}, {}, nil
    for i = 1, NumEntries() do
        local title, isHeader, isCollapsed, isComplete, questID = Entry(i)
        if isHeader then
            header = title
            if isCollapsed and title then collapsed[title] = true end
        elseif title and questID and questID > 0 then
            local state = (isComplete == 1 or isComplete == true) and 1 or (isComplete == -1) and -1 or 0
            quests[questID] = { title = title, state = state, objs = Objectives(i, questID), header = header }
        end
    end
    return quests, collapsed
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

-- Cuts to max bytes without leaving half a letter (accented letters take more than one byte).
local function Cut(s, max)
    if #s <= max then return s end
    s = s:sub(1, max)
    return (s:gsub("[\192-\255][\128-\191]*$", ""))
end

local function Clean(s, max)
    s = tostring(s or ""):gsub("[%^~\r\n]", "")
    return Cut(s, max)
end

local function Encode(id, q)
    local parts = {}
    for _, o in ipairs(q.objs) do
        table.insert(parts, (o[2] and "+" or "-") .. Clean(o[1], 70))
    end
    local msg = "Q^" .. id .. "^" .. q.state .. "^" .. Clean(q.title, 60) .. "^" .. table.concat(parts, "~")
    return Cut(msg, MAX_MSG)
end

local function Decode(msg)
    local id, state, title, objText = msg:match("^Q%^(%d+)%^(%-?%d+)%^([^%^]*)%^?(.*)$")
    if not id then return end
    local objs = {}
    for part in objText:gmatch("[^~]+") do
        table.insert(objs, { part:sub(2), part:sub(1, 1) == "+" })
    end
    return tonumber(id), { title = title, state = tonumber(state) or 0, objs = objs }
end

---------------------------------------------------------------------------
-- Sending (queued, so a full quest log never trips the game's message limit)
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
    if #queue > 0 and not ticker then ticker = C_Timer.NewTicker(0.3, Pump) end
end

-- Re-reads my quest log; when sharing, sends only what changed since last time.
local function UpdateMine()
    local quests, collapsed = Snapshot()
    -- A quest that vanished because its header got collapsed is still in the log: keep it.
    for id, old in pairs(myQuests) do
        if not quests[id] and old.header and collapsed[old.header] then quests[id] = old end
    end
    if Sharing() and Channel() then
        for id, q in pairs(quests) do
            local m = Encode(id, q)
            if lastSent[id] ~= m then lastSent[id] = m; Send(m) end
        end
        for id in pairs(lastSent) do
            if not quests[id] then lastSent[id] = nil; Send("R^" .. id) end
        end
    end
    myQuests = quests
    for id, q in pairs(quests) do seen[id] = q.title end
    Later("done", 3, function() ReportDone() end)
    Later("window", 0.2, function() RefreshWindow() end)
end

-- Tells the group which of the quests they know about I've already finished.
ReportDone = function()
    if not (Sharing() and Channel()) then return end
    for id in pairs(seen) do
        if not sentDone[id] and not myQuests[id] and Completed(id) then
            sentDone[id] = true
            Send("D^" .. id)
        end
    end
end

local function SendFull()
    if not (Sharing() and Channel()) then return end
    -- The full list replaces any quest messages still waiting to go out.
    for i = #queue, 1, -1 do
        if queue[i]:find("^[QRCD]") then table.remove(queue, i) end
    end
    wipe(lastSent)
    wipe(sentDone)
    Send("C^" .. ns.version)
    UpdateMine()
end

local function SayHello()
    if Sharing() then Send("H^" .. PROTOCOL .. "^" .. ns.version) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function ShortName(sender)
    if Ambiguate then return Ambiguate(sender, "none") end
    return sender
end

-- Says so once if a teammate's P13Tweaks is a different version from mine.
local function CheckVersion(who, ver)
    if not ver or ver == ns.version or warned[who .. ver] then return end
    warned[who .. ver] = true
    ns:Print(("%s has P13Tweaks v%s, you have v%s."):format(who, ver, ns.version))
end

local function OnMessage(msg, sender)
    if not Sharing() then return end
    local who = ShortName(sender)
    if who == UnitName("player") then return end
    local kind = msg:sub(1, 1)
    local m = members[who]
    if kind == "H" then
        local proto = tonumber(msg:match("^H%^(%d+)"))
        if not m then m = { quests = {} }; members[who] = m end
        m.protocol = proto
        m.version = msg:match("^H%^%d+%^(.+)$") or m.version
        CheckVersion(who, m.version)
        if proto and proto ~= PROTOCOL and not warned[who] then
            warned[who] = true
            ns:Print(("%s has a %s P13Tweaks, so quest sharing may not work until you both have the latest one.")
                :format(who, proto > PROTOCOL and "newer" or "older"))
        end
        Later("full", 2, SendFull)   -- they just arrived (or reloaded): send them my list
    elseif kind == "C" then
        local ver = msg:match("^C%^(.+)$") or (m and m.version)
        members[who] = { quests = {}, protocol = m and m.protocol, version = ver }
        CheckVersion(who, ver)
    elseif kind == "X" then
        members[who] = nil
    elseif kind == "Q" then
        local id, q = Decode(msg)
        if id then
            if not m then m = { quests = {} }; members[who] = m end
            m.quests[id] = q
            m.done = m.done or {}
            m.done[id] = nil
            seen[id] = q.title
            Later("done", 2, function() ReportDone() end)   -- if I've finished it, say so
        end
    elseif kind == "D" then
        local id = tonumber(msg:match("^D%^(%d+)"))
        if id then
            if not m then m = { quests = {} }; members[who] = m end
            m.done = m.done or {}
            m.done[id] = true
        end
    elseif kind == "R" then
        local id = tonumber(msg:match("^R%^(%d+)"))
        if m and id then m.quests[id] = nil end
    end
    if members[who] then members[who].heard = GetTime() end   -- for "Ask again": did they answer?
    Later("window", 0.2, function() RefreshWindow() end)
end

---------------------------------------------------------------------------
-- Group changes
---------------------------------------------------------------------------

local roster = {}   -- names in my group last time we looked

local function GroupNames()
    local t = {}
    local raid = IsInRaid()
    for i = 1, (GetNumGroupMembers() or 0) do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local name, realm = UnitName(unit)
            if name then t[(realm and realm ~= "") and (name .. "-" .. realm) or name] = true end
        end
    end
    return t
end

local function OnRoster()
    if not Channel() then
        wipe(roster); wipe(queue); wipe(lastSent); wipe(sentDone); wipe(seen)
        for name, m in pairs(members) do if not m.demo then members[name] = nil end end
        RefreshWindow()
        return
    end
    local now = GroupNames()
    for name, m in pairs(members) do
        if not m.demo and not now[name] then members[name] = nil end   -- left the group
    end
    local someoneNew = false
    for name in pairs(now) do if not roster[name] then someoneNew = true end end
    roster = now
    if someoneNew then
        SayHello()                  -- everyone with P13Tweaks answers with their list...
        Later("full", 3, SendFull)  -- ...and they get mine
    end
    RefreshWindow()
end

---------------------------------------------------------------------------
-- Window: /p13 quests
---------------------------------------------------------------------------

local W = 340
local win, content, emptyText
local lines = {}
local btns = {}
local function NameColor(name)
    local _, class = UnitClass(name)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c and c.colorStr then return "|c" .. c.colorStr end
    return "|cff33ff99"
end

local lastCheck   -- lines describing the result of the last "Ask again", shown at the top of the window

-- " v0.3.2" after a player's name: grey when it matches mine, red when it doesn't.
local function VerTag(v)
    if not v then return " |cff808080v?|r" end
    return (v == ns.version and " |cff808080v" or " |cffff6040v") .. v .. "|r"
end

-- "quest" (by quest), "compare" (side by side), "player" (by player)
local function ViewMode()
    local v = ns:Get("questShareView")
    return (v == "player" or v == "compare") and v or "quest"
end
local NEXT_VIEW = { quest = "compare", compare = "player", player = "quest" }
local VIEW_LABEL = { quest = "View: by quest", compare = "View: side by side", player = "View: by player" }

-- Side-by-side layout (pixels)
local CMP_TITLE, CMP_COL, CMP_GAP = 150, 78, 56
local cells = {}   -- pooled FontStrings for the side-by-side columns

local function Cell(i)
    if cells[i] then return cells[i] end
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(false)
    cells[i] = fs
    return fs
end

-- Shares one of my quests with the group (the game's own quest sharing: they get an accept prompt).
local function PushQuest(id)
    if not Channel() then return false, "you're not in a group" end
    local index
    for i = 1, NumEntries() do
        local _, isHeader, _, _, qid = Entry(i)
        if not isHeader and qid == id then index = i; break end
    end
    if SelectQuestLogEntry and index then
        SelectQuestLogEntry(index)
    elseif C_QuestLog and C_QuestLog.SetSelectedQuest then
        C_QuestLog.SetSelectedQuest(id)
    else
        return false, "its zone is collapsed in your quest log - expand it first"
    end
    local can = true
    if C_QuestLog and C_QuestLog.IsPushableQuest then can = C_QuestLog.IsPushableQuest(id)
    elseif GetQuestLogPushable then can = GetQuestLogPushable() end
    if not can then return false, "the game doesn't allow sharing this quest" end
    if not QuestLogPushQuest then return false, "this game version can't share quests" end
    QuestLogPushQuest()
    return true
end

-- Does anyone with P13Tweaks in the group still need this quest (haven't got it, haven't finished it)?
local function NeededBySomeone(id)
    for _, m in pairs(members) do
        if not m.demo and not m.quests[id] and not (m.done and m.done[id]) then return true end
    end
end

local function ShareAll()
    if not Channel() then ns:Print("You're not in a group."); return end
    local ids = {}
    for id in pairs(myQuests) do if NeededBySomeone(id) then table.insert(ids, id) end end
    table.sort(ids, function(a, b) return (myQuests[a].title or "") < (myQuests[b].title or "") end)
    if #ids == 0 then ns:Print("Everyone in your group already has or has finished all your quests."); return end
    ns:Print(("Sharing %d quest%s - your group will get an accept prompt for each."):format(#ids, #ids == 1 and "" or "s"))
    local failed = 0
    for k, id in ipairs(ids) do
        C_Timer.After((k - 1) * 2, function()
            if not PushQuest(id) then failed = failed + 1 end
            if k == #ids and failed > 0 then
                ns:Print(("%d couldn't be shared (the game doesn't allow sharing some quests)."):format(failed))
            end
        end)
    end
end

-- "Ask again": ask everyone to resend, wait a few seconds, then say who answered.
local function AskAgain()
    local t0 = GetTime()
    lastCheck = { "|cff808080Checking...|r" }
    RefreshWindow()
    SayHello()
    ns:Print("Asking your group...")
    C_Timer.After(6, function()
        local names = {}
        for name in pairs(GroupNames()) do table.insert(names, name) end
        table.sort(names)
        local lines = {}
        for _, name in ipairs(names) do
            local m = members[name]
            local line
            if m and m.heard and m.heard >= t0 then
                local n = 0
                for _ in pairs(m.quests) do n = n + 1 end
                line = ("|cff40ff40updated|r - %d quest%s%s"):format(n, n == 1 and "" or "s", VerTag(m.version))
                if m.version and m.version ~= ns.version then line = line .. " |cffff6040(different version)|r" end
            elseif m then
                line = "|cffffd200no answer|r - still showing what they sent before"
            else
                line = "|cffff6040no P13Tweaks|r (or their quest sharing is off)"
            end
            table.insert(lines, NameColor(name) .. name .. "|r: " .. line)
        end
        if #lines == 0 then lines[1] = "Nobody else is in your group." end
        lastCheck = lines
        for _, l in ipairs(lines) do ns:Print(l) end
        RefreshWindow()
    end)
end

local function QuestButton(i)
    if btns[i] then return btns[i] end
    local b = CreateFrame("Button", nil, content)
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    b:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.12)
    b:SetScript("OnClick", function(self)
        if self.guide then   -- a quest I don't have: how do I get it?
            ns.ShowQuestGuide(self.guide, self.guideTitle)
            return
        end
        local ok, why = PushQuest(self.questId)
        if ok then ns:Print("Shared \"" .. (myQuests[self.questId] and myQuests[self.questId].title or "quest") .. "\" with your group.")
        else ns:Print("Couldn't share it: " .. why .. ".") end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.guide and "Click to see how to get this quest" or "Click to share this quest with your group", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btns[i] = b
    return b
end

local function Line(i)
    if lines[i] then return lines[i] end
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    lines[i] = fs
    return fs
end

local function BuildWindow()
    win = CreateFrame("Frame", "P13TweaksTeamQuests", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(W + 50, 440)
    win:SetPoint("CENTER", -200, 0)
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    tinsert(UISpecialFrames, win:GetName())   -- Escape closes it

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Teammates' quests")

    local viewBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    viewBtn:SetSize(112, 20)
    viewBtn:SetPoint("TOPLEFT", 12, -32)
    viewBtn:SetScript("OnClick", function()
        ns:Set("questShareView", NEXT_VIEW[ViewMode()])
        RefreshWindow()
    end)
    win.viewBtn = viewBtn

    local shareBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    shareBtn:SetSize(70, 20)
    shareBtn:SetPoint("LEFT", viewBtn, "RIGHT", 4, 0)
    shareBtn:SetText("Share all")
    shareBtn:SetScript("OnClick", ShareAll)
    shareBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Share every quest of yours that someone in the group still needs", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    shareBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- side-by-side view only: show every quest, or only the ones where players differ
    local diffBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    diffBtn:SetSize(76, 20)
    diffBtn:SetPoint("LEFT", shareBtn, "RIGHT", 4, 0)
    diffBtn:SetScript("OnClick", function()
        ns:Set("questShareDiffOnly", not ns:Get("questShareDiffOnly"))
        RefreshWindow()
    end)
    diffBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Show only the quests where players are at different points", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    diffBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    win.diffBtn = diffBtn

    local ask = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    ask:SetSize(90, 20)
    ask:SetPoint("TOPRIGHT", -12, -32)
    ask:SetText("Ask again")
    ask:SetScript("OnClick", function()
        if not Sharing() then ns:Print("Quest sharing is off - turn it on in /p13."); return end
        if not Channel() then ns:Print("You're not in a group."); return end
        AskAgain()
    end)

    local scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -58)
    scroll:SetPoint("BOTTOMRIGHT", -32, 10)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(W, 1)
    scroll:SetScrollChild(content)

    emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOPLEFT", 4, -4)
    emptyText:SetWidth(W - 8)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetWordWrap(true)

    win:SetScript("OnShow", function() RefreshWindow() end)
end

local function SortedQuests(quests)
    local list = {}
    for id, q in pairs(quests) do table.insert(list, { id = id, q = q }) end
    table.sort(list, function(a, b) return (a.q.title or "") < (b.q.title or "") end)
    return list
end

-- One quest's progress as a short phrase ("3/10, 0/5").
local function Summary(q)
    if q.state == 1 then return "|cff40ff40ready to turn in|r" end
    if q.state == -1 then return "|cffff4040failed|r" end
    local parts = {}
    for _, o in ipairs(q.objs) do
        local count = o[1]:match("(%d+%s*/%s*%d+)")
        if count then table.insert(parts, o[2] and ("|cff808080" .. count .. "|r") or count)
        else table.insert(parts, o[2] and "|cff808080done|r" or Cut(o[1], 30)) end
    end
    if #parts == 0 then return "in progress" end
    return table.concat(parts, ", ")
end

-- By quest: every quest anyone has, with each player's place on it - including players who haven't started it.
local function BuildByQuest(out)
    local players = {}
    local _, myClass = UnitClass("player")
    local mc = myClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[myClass]
    table.insert(players, { name = "You", color = mc and mc.colorStr and ("|c" .. mc.colorStr) or "|cff33ff99",
        quests = myQuests, isDone = Completed })
    local names = {}
    for name in pairs(members) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local m = members[name]
        table.insert(players, { name = name, color = NameColor(name), quests = m.quests,
            isDone = function(id) return m.done and m.done[id] end })
    end
    if #names == 0 then return end

    local ids, title = {}, {}
    for _, p in ipairs(players) do
        for id, q in pairs(p.quests) do
            if not title[id] then title[id] = q.title or seen[id] or "?"; table.insert(ids, id) end
        end
    end
    table.sort(ids, function(a, b) return title[a] < title[b] end)

    local missing = {}
    for name in pairs(GroupNames()) do if not members[name] then table.insert(missing, name) end end
    table.sort(missing)
    table.insert(out, { "|cff808080Click one of your quests to share it; click one you don't have to see how to get it.|r", 0, 2 })
    if #missing > 0 then
        table.insert(out, { "|cff808080No P13Tweaks (can't be shown): " .. table.concat(missing, ", ") .. "|r", 0, 2 })
    end
    if #ids == 0 then table.insert(out, { "|cff808080(nobody has any quests)|r", 0, 8 }) end

    for _, id in ipairs(ids) do
        table.insert(out, { "|cffffd200" .. title[id] .. "|r", 0, 10, myQuests[id] and id or nil,
            guide = (not myQuests[id]) and id or nil })
        for _, p in ipairs(players) do
            if p.name ~= "You" then   -- you're already in your own quest log; only show teammates
                local q = p.quests[id]
                local status = q and Summary(q) or (p.isDone(id) and "|cff40c0ffalready completed|r") or "|cff808080not started|r"
                table.insert(out, { p.color .. p.name .. "|r" .. VerTag(members[p.name].version) .. ": " .. status, 14, 1 })
            end
        end
    end
end

-- By player: each teammate's quest log.
local function BuildByPlayer(out)
    local names = {}
    for name in pairs(members) do table.insert(names, name) end
    table.sort(names)

    for _, name in ipairs(names) do
        local m = members[name]
        table.insert(out, { NameColor(name) .. name .. "|r" .. VerTag(m.version), 0, #out > 0 and 14 or 0 })
        local list = SortedQuests(m.quests)
        if #list == 0 then table.insert(out, { "|cff808080(no quests)|r", 12, 2 }) end
        for _, e in ipairs(list) do
            local q = e.q
            local t = "|cffffd200" .. (q.title or "?") .. "|r"
            if q.state == 1 then t = t .. " |cff40ff40(ready to turn in)|r"
            elseif q.state == -1 then t = t .. " |cffff4040(failed)|r" end
            if myQuests[e.id] and not m.demo then t = t .. " |cff8fa8ff(you have it too)|r" end
            table.insert(out, { t, 12, 4, guide = (not myQuests[e.id]) and e.id or nil })
            if q.state ~= 1 then
                for _, o in ipairs(q.objs) do
                    table.insert(out, { (o[2] and "|cff808080" or "|cffffffff") .. o[1] .. "|r", 26, 1 })
                end
            end
        end
    end
end

-- One player's place on one quest for the side-by-side view.
-- Returns text, progress (0..1, nil = hasn't started), kind ("ok", "ready", "failed", "done", "none").
local function CompareCell(q, done)
    if q then
        if q.state == 1 then return "ready", 1, "ready" end
        if q.state == -1 then return "failed", 0, "failed" end
        local have, need, count = 0, 0, nil
        for _, o in ipairs(q.objs) do
            local a, b = o[1]:match("(%d+)%s*/%s*(%d+)")
            if a then
                have = have + tonumber(a); need = need + tonumber(b); count = a .. "/" .. b
            else
                need = need + 1
                if o[2] then have = have + 1 end
            end
        end
        if need == 0 then return "...", 0, "ok" end
        local frac = math.min(1, have / need)
        local text = (#q.objs == 1 and count) or (math.floor(frac * 100 + 0.5) .. "%")
        return text, frac, "ok"
    end
    if done then return "done", 1, "done" end
    return "-", nil, "none"
end

local KIND_COLOR = { ready = "|cff40ff40", failed = "|cffff4040", done = "|cff40c0ff", none = "|cff808080" }

-- Side by side: one column per player (you first), one row per quest, plus a gap column.
-- Whoever is furthest along on a quest is green, anyone behind is amber.
local function BuildCompare(out)
    local players = {}
    local _, myClass = UnitClass("player")
    local mc = myClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[myClass]
    table.insert(players, { name = "You", color = mc and mc.colorStr and ("|c" .. mc.colorStr) or "|cff33ff99",
        quests = myQuests, isDone = Completed, version = ns.version })
    local names = {}
    for name in pairs(members) do table.insert(names, name) end
    table.sort(names)
    if #names == 0 then return end
    for _, name in ipairs(names) do
        local m = members[name]
        table.insert(players, { name = name, color = NameColor(name), quests = m.quests, version = m.version,
            isDone = function(id) return m.done and m.done[id] end })
    end
    local n = #players
    local gapX = CMP_TITLE + n * CMP_COL

    -- every quest anyone has
    local title, ids = {}, {}
    for _, p in ipairs(players) do
        for id, q in pairs(p.quests) do
            if not title[id] then title[id] = q.title or seen[id] or "?"; table.insert(ids, id) end
        end
    end

    -- compute each row
    local rows = {}
    for _, id in ipairs(ids) do
        local texts, scores, kinds = {}, {}, {}
        local best, worst, differs = -1, 2, false
        for i, p in ipairs(players) do
            local t, s, k = CompareCell(p.quests[id], p.isDone(id))
            texts[i], scores[i], kinds[i] = t, s, k
            local v = s or 0
            if v > best then best = v end
            if v < worst then worst = v end
            if t ~= texts[1] then differs = true end
        end
        table.insert(rows, { id = id, texts = texts, scores = scores, kinds = kinds, best = best,
            gap = math.floor((best - worst) * 100 + 0.5), differs = differs })
    end
    local diffOnly = ns:Get("questShareDiffOnly")
    table.sort(rows, function(a, b)
        if a.differs ~= b.differs then return a.differs end
        return title[a.id] < title[b.id]
    end)

    -- header
    local head = { "|cff808080Quest|r", 0, 0, nil, cells = {}, titleW = CMP_TITLE, nowrap = true }
    for i, p in ipairs(players) do
        table.insert(head.cells, { x = CMP_TITLE + (i - 1) * CMP_COL, w = CMP_COL,
            text = p.color .. p.name .. "|r\n" .. VerTag(p.version):gsub("^ ", "") })
    end
    table.insert(head.cells, { x = gapX, w = CMP_GAP, text = "|cff808080gap|r" })
    table.insert(out, head)

    local shown = 0
    for _, r in ipairs(rows) do
        if r.differs or not diffOnly then
            shown = shown + 1
            local e = { (r.differs and "|cffffd200" or "|cffa0a070") .. title[r.id] .. "|r", 0, 5,
                myQuests[r.id] and r.id or nil, cells = {}, titleW = CMP_TITLE, nowrap = true,
                guide = (not myQuests[r.id]) and r.id or nil }
            for i = 1, n do
                local kind, color = r.kinds[i], nil
                if kind == "ok" then
                    color = (r.scores[i] or 0) >= r.best - 0.001 and "|cff40ff40" or "|cffffa040"
                else
                    color = KIND_COLOR[kind]
                end
                table.insert(e.cells, { x = CMP_TITLE + (i - 1) * CMP_COL, w = CMP_COL, text = color .. r.texts[i] .. "|r" })
            end
            local gapText = not r.differs and "|cff808080same|r"
                or (r.gap > 0 and ("|cffffa040" .. r.gap .. "%|r")) or "|cffffa040~|r"
            table.insert(e.cells, { x = gapX, w = CMP_GAP, text = gapText })
            table.insert(out, e)
        end
    end
    if shown == 0 then
        table.insert(out, { "|cff808080(everyone is in the same place on every quest)|r", 0, 8 })
    end
    table.insert(out, { "|cff808080green = furthest along, amber = behind, - = not started. Click one of your quests to share it, or one you don't have to see how to get it.|r", 0, 10 })
end

RefreshWindow = function()
    if not (win and win:IsShown()) then return end
    local mode = ViewMode()
    win.viewBtn:SetText(VIEW_LABEL[mode])
    win.diffBtn:SetShown(mode == "compare")
    win.diffBtn:SetText(ns:Get("questShareDiffOnly") and "Show: diffs" or "Show: all")

    -- The side-by-side view is as wide as it needs to be; the others use the normal width.
    local wantW = 340
    if mode == "compare" then
        local count = 1
        for _ in pairs(members) do count = count + 1 end
        wantW = math.min(900, math.max(340, CMP_TITLE + count * CMP_COL + CMP_GAP))
    end
    if wantW ~= W then
        W = wantW
        win:SetWidth(W + 50)
        content:SetWidth(W)
        emptyText:SetWidth(W - 8)
    end

    -- Lines are { text, indent, gapBefore, questId (when clicking it shares that quest) };
    -- side-by-side rows also carry .cells (the columns), .titleW and .nowrap.
    local out = {}
    if mode == "quest" then BuildByQuest(out)
    elseif mode == "compare" then BuildCompare(out)
    else BuildByPlayer(out) end

    -- Result of the last "Ask again" goes on top.
    local checkText
    if lastCheck then
        if #out > 0 then
            local top = { { "|cff808080Last check:|r", 0, 0 } }
            for _, l in ipairs(lastCheck) do table.insert(top, { l, 8, 1 }) end
            for i = #top, 1, -1 do table.insert(out, 1, top[i]) end
            if out[#top + 1] then out[#top + 1][3] = math.max(out[#top + 1][3], 10) end
        else
            checkText = table.concat(lastCheck, "\n")
        end
    end

    local y = 0
    local nb, nc = 0, 0
    for i, e in ipairs(out) do
        local fs = Line(i)
        y = y + e[3]
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", e[2], -y)
        fs:SetWidth(e.titleW or (W - e[2]))
        fs:SetWordWrap(not e.nowrap)
        fs:SetText(e[1])
        fs:Show()
        local h = fs:GetStringHeight()
        for _, c in ipairs(e.cells or {}) do
            nc = nc + 1
            local cf = Cell(nc)
            cf:ClearAllPoints()
            cf:SetPoint("TOPLEFT", c.x, -y)
            cf:SetWidth(c.w)
            cf:SetText(c.text)
            cf:Show()
            h = math.max(h, cf:GetStringHeight())
        end
        local guide = e.guide and ns.ShowQuestGuide and ns:Get("questHow") and e.guide or nil
        if e[4] or guide then
            nb = nb + 1
            local b = QuestButton(nb)
            b.questId = e[4]
            b.guide = guide
            b.guideTitle = guide and (e[1]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r.*$", "")) or nil
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", e[2], -y)
            b:SetSize(e.titleW or (W - e[2]), h)
            b:Show()
        end
        y = y + h
    end
    for i = #out + 1, #lines do lines[i]:Hide() end
    for i = nb + 1, #btns do btns[i]:Hide() end
    for i = nc + 1, #cells do cells[i]:Hide() end

    if #out == 0 then
        local why = not Sharing() and "Quest sharing is off. Turn it on in /p13."
            or not Channel() and "You're not in a group."
            or "Nobody in your group is sharing quests yet."
        emptyText:SetText(why .. "\n\nTeammates show up here when you're grouped and they have P13Tweaks too, with quest sharing on."
            .. (checkText and ("\n\nLast check:\n" .. checkText) or ""))
        emptyText:Show()
        y = emptyText:GetStringHeight() + 8
    else
        emptyText:Hide()
    end
    content:SetHeight(math.max(1, y))
end

local function ToggleWindow()
    if not win then BuildWindow() end
    if win:IsShown() then win:Hide() else win:Show(); win:Raise() end
end

---------------------------------------------------------------------------
-- Tooltips: "Name: 3/10" on mobs and items a teammate's quest needs
---------------------------------------------------------------------------

local function AddProgress(tt, name)
    if not (Sharing() and ns:Get("questShareTooltips")) or not name or #name < 3 then return end
    local low = name:lower()
    local added = false
    for who, m in pairs(members) do
        for _, q in pairs(m.quests) do
            if q.state ~= 1 then
                for _, o in ipairs(q.objs) do
                    if o[1]:lower():find(low, 1, true) then
                        local count = o[1]:match("(%d+%s*/%s*%d+)")
                        local state = o[2] and "|cff808080done|r" or count or "needed"
                        if not added then tt:AddLine(" ") end
                        tt:AddLine(NameColor(who) .. who .. "|r: " .. state, 1, 1, 1)
                        added = true
                    end
                end
            end
        end
    end
    if added then tt:Show() end
end

local function OnUnitTooltip(tt)
    if tt ~= GameTooltip then return end
    local ok, name, unit = pcall(tt.GetUnit, tt)
    if not ok or not unit or UnitIsPlayer(unit) then return end
    AddProgress(tt, name)
end

local function OnItemTooltip(tt)
    if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
    local ok, name = pcall(tt.GetItem, tt)
    if ok then AddProgress(tt, name) end
end

local function HookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
    else
        GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
        GameTooltip:HookScript("OnTooltipSetItem", OnItemTooltip)
        if ItemRefTooltip then ItemRefTooltip:HookScript("OnTooltipSetItem", OnItemTooltip) end
    end
end

---------------------------------------------------------------------------
-- Options and commands
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "questShare",
    type = "toggleButton",
    label = "Share quests with my group",
    buttonText = "View",
    buttonWidth = 60,
    onClick = function() ToggleWindow() end,
    tooltip = "Sends your quests and their progress to group members who also have P13Tweaks, and shows theirs.\n\nView (or /p13 quests) opens the list of your teammates' quests. Teammates without P13Tweaks can't show up: the game doesn't let addons read someone else's quest log.",
    default = true,
    onChange = function(on)
        if on then
            wipe(roster); wipe(lastSent); wipe(sentDone)
            OnRoster()   -- says hello and sends my list if I'm in a group
        else
            Send("X")
            wipe(lastSent)
            for name, m in pairs(members) do if not m.demo then members[name] = nil end end
            RefreshWindow()
        end
    end,
})

ns:RegisterOption({
    key = "questShareTooltips",
    type = "toggle",
    label = "Show teammates' quest progress on tooltips",
    tooltip = "When you hover over an enemy or item that a teammate's quest needs, the tooltip shows their progress, e.g. \"Name: 3/10\". Needs quest sharing on.",
    default = true,
})

ns:RegisterOption({
    key = "questShareAuto",
    type = "toggle",
    label = "Auto-accept quests my group shares with me",
    tooltip = "When a group member shares a quest with you, it's accepted straight away instead of asking. Off by default.",
    default = false,
})

ns:RegisterCommand("quests", "show your teammates' quests and progress", function()
    ToggleWindow()
end)

ns:RegisterCommand("version", "show your P13Tweaks version and your teammates'", function()
    ns:Print("you have v" .. ns.version)
    for name, m in pairs(members) do
        if not m.demo then
            ns:Print(("%s has %s"):format(name, m.version and ("v" .. m.version .. (m.version == ns.version and " (same)" or " (DIFFERENT)")) or "an older P13Tweaks that doesn't report its version"))
        end
    end
end)

-- Pretend teammates for testing alone. They start from a copy of your quest log, then differ from it
-- in set ways so every case in the window shows up: behind, ahead, ready to turn in, not started,
-- already done, a quest only they have, and a different P13Tweaks version.
local DEMO_PEOPLE = { "Demo Ann", "Demo Bob" }

local function MakeDemo(which)
    local ids = {}
    for id in pairs(myQuests) do table.insert(ids, id) end
    table.sort(ids)
    local quests, done = {}, {}
    for k, id in ipairs(ids) do
        local q = myQuests[id]
        local objs = {}
        for _, o in ipairs(q.objs) do table.insert(objs, { o[1], o[2] }) end
        local copy = { title = q.title, state = q.state, objs = objs }
        local pattern = (k + which) % 4
        if which == 1 then
            if pattern == 0 then copy = nil; done[id] = true            -- not in the log: finished it already
            elseif pattern == 1 then                                    -- behind: half the counts
                for _, o in ipairs(copy.objs) do
                    o[1] = o[1]:gsub("(%d+)%s*/%s*(%d+)", function(a, b) return math.floor(a / 2) .. "/" .. b end)
                    o[2] = false
                end
                copy.state = 0
            elseif pattern == 3 then copy.state = 1 end                 -- ready to turn in
        else
            if pattern == 2 then copy = nil                             -- hasn't started it
            elseif pattern == 0 then                                    -- a quarter of the way
                for _, o in ipairs(copy.objs) do
                    o[1] = o[1]:gsub("(%d+)%s*/%s*(%d+)", function(a, b) return math.floor(a / 4) .. "/" .. b end)
                    o[2] = false
                end
                copy.state = 0
            end
        end
        if copy then quests[id] = copy end
    end
    -- quests that only the pretend teammates have (so this works with an empty quest log too)
    quests[9990001] = { title = "Demo: Boars In The Hills", state = 0, objs = { { "Boars slain: " .. (which == 1 and "2" or "7") .. "/10", false } } }
    quests[9990002] = { title = "Demo: Lost Supplies", state = 0, objs = { { "Crates found: " .. (which == 1 and "3" or "0") .. "/3", which == 1 }, { "Scout spoken to: 0/1", false } } }
    return { quests = quests, done = done, demo = true, version = which == 1 and ns.version or "0.3.9" }
end

ns:RegisterCommand("questsdemo", "add (or remove) two pretend teammates to try the quest window alone", function()
    if members[DEMO_PEOPLE[1]] then
        for _, name in ipairs(DEMO_PEOPLE) do members[name] = nil end
        ns:Print("Pretend teammates removed.")
    else
        UpdateMine()
        for i, name in ipairs(DEMO_PEOPLE) do members[name] = MakeDemo(i) end
        ns:Print("Added pretend teammates Demo Ann and Demo Bob (they differ from your quests so every case shows; Bob has an older version). Hover a quest mob or item, or switch views in the window. Type /p13 questsdemo again to remove them.")
    end
    if not win then BuildWindow() end
    win:Show()
    RefreshWindow()
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
elseif RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(PREFIX)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("QUEST_DETAIL")
frame:SetScript("OnEvent", function(self, event, a1, a2, a3, a4)
    if event == "PLAYER_LOGIN" then
        pcall(HookTooltips)
    elseif event == "QUEST_DETAIL" then
        -- A group member shared a quest: the "npc" giving it is a player in my group.
        if ns:Get("questShareAuto") and UnitIsPlayer("npc") and (UnitInParty("npc") or UnitInRaid("npc")) then
            pcall(AcceptQuest)
        end
    elseif event == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 and a4 then OnMessage(a2, a4) end
    elseif event == "QUEST_LOG_UPDATE" then
        Later("mine", 1, UpdateMine)   -- this event fires a lot; one look a second is plenty
    else
        -- PLAYER_ENTERING_WORLD (login, /reload) and GROUP_ROSTER_UPDATE
        Later("roster", 1, OnRoster)
    end
end)

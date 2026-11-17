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
local ADDON_NAME, ns = ...

local PREFIX = "P13Q"
local PROTOCOL = 1             -- bump when the message format changes
local MAX_MSG = 250            -- the game allows 255 bytes per addon message
local BURST, REFILL = 8, 1.1   -- send up to 8 at once, then one every 1.1 s (under the game's limit)
local DEMO = "Demo (you)"      -- fake teammate made by /p13 questsdemo

local members = {}    -- name -> { quests = { [id] = { title, state, objs = { {text, done} } } }, protocol, demo }
local myQuests = {}   -- my own quest log, same shape (plus .header)
local lastSent = {}   -- id -> the message we last sent for that quest
local warned = {}     -- name -> true once we've said their P13Tweaks is a different version
local RefreshWindow   -- set further down

local function Sharing() return ns:Get("questShare") end

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
    Later("window", 0.2, function() RefreshWindow() end)
end

local function SendFull()
    if not (Sharing() and Channel()) then return end
    -- The full list replaces any quest messages still waiting to go out.
    for i = #queue, 1, -1 do
        if queue[i]:find("^[QRC]") then table.remove(queue, i) end
    end
    wipe(lastSent)
    Send("C")
    UpdateMine()
end

local function SayHello()
    if Sharing() then Send("H^" .. PROTOCOL) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function ShortName(sender)
    if Ambiguate then return Ambiguate(sender, "none") end
    return sender
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
        if proto and proto ~= PROTOCOL and not warned[who] then
            warned[who] = true
            ns:Print(("%s has a %s P13Tweaks, so quest sharing may not work until you both have the latest one.")
                :format(who, proto > PROTOCOL and "newer" or "older"))
        end
        Later("full", 2, SendFull)   -- they just arrived (or reloaded): send them my list
    elseif kind == "C" then
        members[who] = { quests = {}, protocol = m and m.protocol }
    elseif kind == "X" then
        members[who] = nil
    elseif kind == "Q" then
        local id, q = Decode(msg)
        if id then
            if not m then m = { quests = {} }; members[who] = m end
            m.quests[id] = q
        end
    elseif kind == "R" then
        local id = tonumber(msg:match("^R%^(%d+)"))
        if m and id then m.quests[id] = nil end
    end
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
        wipe(roster); wipe(queue); wipe(lastSent)
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

local W = 300
local win, content, emptyText
local lines = {}

local function Line(i)
    if lines[i] then return lines[i] end
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    lines[i] = fs
    return fs
end

local function NameColor(name)
    local _, class = UnitClass(name)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c and c.colorStr then return "|c" .. c.colorStr end
    return "|cff33ff99"
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

    local ask = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    ask:SetSize(90, 20)
    ask:SetPoint("TOPRIGHT", -12, -32)
    ask:SetText("Ask again")
    ask:SetScript("OnClick", function()
        if not Sharing() then ns:Print("Quest sharing is off - turn it on in /p13."); return end
        if not Channel() then ns:Print("You're not in a group."); return end
        SayHello()
        ns:Print("Asked your group to send their quests again.")
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

RefreshWindow = function()
    if not (win and win:IsShown()) then return end

    -- Build the lines as { text, indent, gapBefore }.
    local out = {}
    local names = {}
    for name in pairs(members) do table.insert(names, name) end
    table.sort(names)

    for _, name in ipairs(names) do
        local m = members[name]
        table.insert(out, { NameColor(name) .. name .. "|r", 0, #out > 0 and 14 or 0 })
        local list = SortedQuests(m.quests)
        if #list == 0 then table.insert(out, { "|cff808080(no quests)|r", 12, 2 }) end
        for _, e in ipairs(list) do
            local q = e.q
            local t = "|cffffd200" .. (q.title or "?") .. "|r"
            if q.state == 1 then t = t .. " |cff40ff40(ready to turn in)|r"
            elseif q.state == -1 then t = t .. " |cffff4040(failed)|r" end
            if myQuests[e.id] and not m.demo then t = t .. " |cff8fa8ff(you have it too)|r" end
            table.insert(out, { t, 12, 4 })
            if q.state ~= 1 then
                for _, o in ipairs(q.objs) do
                    table.insert(out, { (o[2] and "|cff808080" or "|cffffffff") .. o[1] .. "|r", 26, 1 })
                end
            end
        end
    end

    local y = 0
    for i, e in ipairs(out) do
        local fs = Line(i)
        y = y + e[3]
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", e[2], -y)
        fs:SetWidth(W - e[2])
        fs:SetText(e[1])
        fs:Show()
        y = y + fs:GetStringHeight()
    end
    for i = #out + 1, #lines do lines[i]:Hide() end

    if #out == 0 then
        local why = not Sharing() and "Quest sharing is off. Turn it on in /p13."
            or not Channel() and "You're not in a group."
            or "Nobody in your group is sharing quests yet."
        emptyText:SetText(why .. "\n\nTeammates show up here when you're grouped and they have P13Tweaks too, with quest sharing on.")
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
            wipe(roster); wipe(lastSent)
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

ns:RegisterCommand("quests", "show your teammates' quests and progress", function()
    ToggleWindow()
end)

ns:RegisterCommand("questsdemo", "add (or remove) a pretend teammate with your own quests, to try the window and tooltips alone", function()
    if members[DEMO] then
        members[DEMO] = nil
        ns:Print("Pretend teammate removed.")
    else
        UpdateMine()
        local copy = {}
        for id, q in pairs(myQuests) do
            local objs = {}
            for _, o in ipairs(q.objs) do table.insert(objs, { o[1], o[2] }) end
            copy[id] = { title = q.title, state = q.state, objs = objs }
        end
        members[DEMO] = { quests = copy, demo = true }
        ns:Print("Added a pretend teammate with your own quests. Hover a quest mob or item, or type /p13 quests. Type /p13 questsdemo again to remove it.")
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
frame:SetScript("OnEvent", function(self, event, a1, a2, a3, a4)
    if event == "PLAYER_LOGIN" then
        pcall(HookTooltips)
    elseif event == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 and a4 then OnMessage(a2, a4) end
    elseif event == "QUEST_LOG_UPDATE" then
        Later("mine", 1, UpdateMine)   -- this event fires a lot; one look a second is plenty
    else
        -- PLAYER_ENTERING_WORLD (login, /reload) and GROUP_ROSTER_UPDATE
        Later("roster", 1, OnRoster)
    end
end)

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
--   V^<rec>;<rec>...  (0.9.0+) compact quests, several per message: rec = <id>:<state>:<obj>,<obj>.. with
--                      obj = + or - (done / not done) plus the count ("3/10") when it has one. No wording.
--   N^<id>,<id>...     "I don't know the wording of these quests": answered with T for the ones the sender has
--   T^<id>^<title>^<tpl>~<tpl>   a quest's wording (objective templates use {c} for the count); receivers keep it
--                      in P13TweaksDB.questText, so only quests nobody has seen before cost a message
--   (V is only sent when every group member known to run P13Tweaks is on 0.9.0+; otherwise Q, as above)
--   R^<id>             that quest left my log
--   X                  I turned sharing off: forget me
--   F^<hash>^<n>       (0.11.0+) fingerprint of my quest log (hash of every quest record, n quests): sent after my quests change,
--                      after a full list and every 30 s. Teammates compare it with their copy of my quests; a mismatch that
--                      persists 3 s makes them answer with Y
--   Y^<name>           "<name>, please resend your full list" (answered with C ... E)
--   F^<hash>^<n>^<chash>  (0.13.0+) the 3rd field fingerprints EVERYTHING I have completed; a teammate whose copy differs asks
--   Z^<name>           "<name>, send me everything you have completed" (rate-limited), answered with K pieces:
--   K^<count>^<chash>^<part>^<parts>^<data>   completed quest ids, sorted, as base-64 gaps (5 bits per char, +32 = more digits)
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
local incoming = {}   -- full lists still arriving (see the Receiving section)
local noticed = {}    -- "name:questId" -> true once I've said a teammate finished a quest I have
local lastF = {}      -- name -> { hex, n, at }: the quest-log fingerprint a teammate last announced
local askedY = {}     -- name -> when I last asked them to resend their list
local askedZ = {}     -- name -> when I last asked them for their completed-quests list
local doneParts = {}  -- name -> pieces of a completed-quests list still arriving
local candDirtyFlag = { v = true }   -- set when teammates' finished-quest lists change (so the "catch up" candidates are rebuilt)
local CheckFingerprint   -- set further down
local wanted = {}     -- quest id -> true: a teammate's quest whose title/objective wording I don't have yet
local askedAt = {}    -- quest id -> when I last asked the group for its wording
local sentText = {}   -- quest id -> when I last sent its wording to the group
-- Counters for /p13 questsdebug (to spot a sync that keeps repeating).
local stats = { hello = 0, full = 0, apply = 0, newcomer = 0, msg = {} }
local seen = {}       -- id -> title: every quest anyone in the group has had in their log
local sentDone = {}   -- id -> true once I've told the group I finished it
local RefreshWindow   -- set further down
local ReportDone      -- set further down
local RememberAll     -- set further down: saves teammates' last known quests
local SyncGhosts      -- set further down: shows saved quests of teammates who aren't here

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

-- Compact format (protocol "V"): a quest is just its id, state and numbers; the wording (title, "Boars slain: {c}")
-- is sent once per quest ("T") and remembered, so a full sync is a few messages instead of one per quest.
--   record = <id>:<state>:<obj>,<obj>...   obj = + or - (done / not done) followed by the count ("3/10"), if it has one
local cacheAdds = 0

local function TextCache()
    P13TweaksDB.questText = P13TweaksDB.questText or {}
    return P13TweaksDB.questText
end

-- "Boars slain: 3/10" -> template "Boars slain: {c}" and count "3/10" (count is nil if the text has none)
local function Split(text)
    local h, n = text:match("(%d+)%s*/%s*(%d+)")
    if not h then return text, nil end
    local tpl = text:gsub("%d+%s*/%s*%d+", "{c}", 1)
    return tpl, h .. "/" .. n
end

local function EncodeRecord(id, q)
    local parts = {}
    for _, o in ipairs(q.objs) do
        local _, count = Split(o[1])
        parts[#parts + 1] = (o[2] and "+" or "-") .. (count or "")
    end
    return id .. ":" .. q.state .. ":" .. table.concat(parts, ",")
end

-- The wording of one of my quests, for teammates who don't know it yet.
local function EncodeText(id, q)
    local tpls = {}
    for i, o in ipairs(q.objs) do tpls[i] = Clean((Split(o[1])), 70) end
    return Cut("T^" .. id .. "^" .. Clean(q.title, 60) .. "^" .. table.concat(tpls, "~"), MAX_MSG)
end

-- Remember a quest's wording (from an old-format "Q" message, which carries it).
local function CacheText(id, title, objs)
    local cache = TextCache()
    cacheAdds = cacheAdds + 1
    if cacheAdds >= 500 then
        cacheAdds = 0
        local n = 0
        for _ in pairs(cache) do n = n + 1 end
        if n > 6000 then wipe(cache) end   -- keep the saved file small
    end
    local tpl = {}
    for i, o in ipairs(objs) do tpl[i] = (Split(o[1])) end
    cache[id] = { title = title, tpl = tpl }
end

-- Turns a compact record back into the quest table the windows use. Second result: do we know its wording?
local function BuildQuest(id, state, objStr)
    local c = TextCache()[id]
    local objs, i = {}, 0
    for tok in (objStr or ""):gmatch("[^,]+") do
        i = i + 1
        local done = tok:sub(1, 1) == "+"
        local count = tok:sub(2)
        local tpl = c and c.tpl and c.tpl[i]
        local text
        if tpl then
            text = (count ~= "" and (tpl:gsub("{c}", count))) or tpl
        else
            text = count ~= "" and count or (done and "done" or "...")
        end
        objs[i] = { text, done }
    end
    local title = (c and c.title) or (ns.QuestName and ns.QuestName(id)) or ("Quest " .. id)
    return { title = title, state = state, objs = objs, raw = objStr or "" }, c ~= nil
end

-- 0.9.0 and later understand the compact format.
local MODERN = "0.9.0"
local function VerAtLeast(v, need)
    if type(v) ~= "string" then return false end
    local a1, a2, a3 = v:match("^(%d+)%.(%d+)%.(%d+)")
    local b1, b2, b3 = need:match("^(%d+)%.(%d+)%.(%d+)")
    if not (a1 and b1) then return false end
    a1, a2, a3, b1, b2, b3 = tonumber(a1), tonumber(a2), tonumber(a3), tonumber(b1), tonumber(b2), tonumber(b3)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 >= b3
end

-- Can everyone I know of in the group read the compact format? (If someone's version is older or unknown, I
-- send the old one-message-per-quest format to everyone, which every version understands.)
local function Modern()
    for _, m in pairs(members) do
        if not m.demo and not m.ghost and not VerAtLeast(m.version, MODERN) then return false end
    end
    for _, p in pairs(incoming) do
        if not VerAtLeast(p.m.version, MODERN) then return false end
    end
    return true
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

-- Sends these quests (ids) of mine: packed several to a message when everyone understands it, else one by one.
local function SendQuests(ids, quests)
    if #ids == 0 then return end
    table.sort(ids)
    if Modern() then
        local body, len = {}, 2
        local function Flush()
            if #body > 0 then Send("V^" .. table.concat(body, ";")) end
            body, len = {}, 2
        end
        for _, id in ipairs(ids) do
            local rec = EncodeRecord(id, quests[id])
            if len + #rec + 1 > MAX_MSG - 2 then Flush() end
            body[#body + 1] = rec
            len = len + #rec + 1
        end
        Flush()
    else
        for _, id in ipairs(ids) do Send(Encode(id, quests[id])) end
    end
end

-- Remembers a quest id seen in the group, plus the quests that decide whether someone can take it
-- (earlier quests in its chain, exclusive ones): everyone then reports those they've finished.
local function Track(id, title)
    seen[id] = title or seen[id] or true
    if ns.QuestRelated then
        for _, r in ipairs(ns.QuestRelated(id)) do
            if not seen[r] then seen[r] = true end
        end
    end
end

-- Tells the group my level, race, class and how full my quest log is, so they can tell whether I can accept a quest.
local lastCount
local function SendProfile()
    if not (Sharing() and Channel()) then return end
    local _, _, raceId = UnitRace("player")
    local _, _, classId = UnitClass("player")
    local n = 0
    for _ in pairs(myQuests) do n = n + 1 end
    lastCount = n
    Send(("P^%d^%d^%d^%d"):format(UnitLevel("player") or 0, raceId or 0, classId or 0, n))
end

-- Every quest I've ever completed (not just the ones in anyone's log), so teammates can see what I've already done.
-- Sent on request ("K" messages) as sorted ids, each stored as the gap from the one before, in base-64 digits:
-- 5 bits per character, +32 on a character means "more digits follow". A few thousand quests = a few thousand characters.
local K64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local K64DEC = {}
for i = 1, 64 do K64DEC[K64:sub(i, i)] = i - 1 end

local function CompletedList()
    local ids = {}
    if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
        for _, id in ipairs(C_QuestLog.GetAllCompletedQuestIDs() or {}) do ids[#ids + 1] = id end
    elseif GetQuestsCompleted then
        for id, v in pairs(GetQuestsCompleted() or {}) do if v then ids[#ids + 1] = id end end
    end
    table.sort(ids)
    return ids
end

local function HashIds(ids)
    local h = 5381
    for _, id in ipairs(ids) do h = (h * 33 + id) % 4294967296 end
    return ("%04x%04x"):format(math.floor(h / 65536), h % 65536)
end

local function EncodeIds(ids)
    local out, prev = {}, 0
    for _, id in ipairs(ids) do
        local d = id - prev
        prev = id
        repeat
            local part = d % 32
            d = math.floor(d / 32)
            local v = part + (d > 0 and 32 or 0)
            out[#out + 1] = K64:sub(v + 1, v + 1)
        until d == 0
    end
    return table.concat(out)
end

-- Returns a set { [id] = true }, or nil if the text isn't valid.
local function DecodeIds(s)
    local set, prev, acc, mul = {}, 0, 0, 1
    for i = 1, #s do
        local v = K64DEC[s:sub(i, i)]
        if not v then return nil end
        acc = acc + (v % 32) * mul
        if v < 32 then
            prev = prev + acc
            set[prev] = true
            acc, mul = 0, 1
        else
            mul = mul * 32
        end
    end
    return set
end

-- My completed list and its hash, recalculated when a quest left my log or after a minute.
local compCache = { ids = nil, hex = "00000000", at = -1000, dirty = true }
local function CompletedInfo()
    if compCache.ids and not compCache.dirty and GetTime() - compCache.at < 60 then return compCache end
    compCache.ids = CompletedList()
    compCache.hex = #compCache.ids > 0 and HashIds(compCache.ids) or "00000000"
    compCache.at = GetTime()
    compCache.dirty = false
    return compCache
end

-- A quick "hash check" of a quest log: a short fingerprint of every quest's id, state and counts. Two clients that
-- hold the same list get the same fingerprint, so a teammate's "F" message tells me in a few bytes whether my copy
-- of their log is complete and current - no need to resend anything when it matches.
local function Fingerprint(quests)
    local ids = {}
    for id in pairs(quests) do ids[#ids + 1] = id end
    table.sort(ids)
    local h = 5381
    for _, id in ipairs(ids) do
        local rec = EncodeRecord(id, quests[id]) .. ";"
        for i = 1, #rec do h = (h * 33 + rec:byte(i)) % 4294967296 end
    end
    return ("%04x%04x"):format(math.floor(h / 65536), h % 65536), #ids
end

-- Announce my fingerprint (a ~20-byte message): teammates compare it with their copy of my quests and ask me to
-- resend if it differs. Sent after my quests change, when I finish a full list, and every 30 s as a heartbeat.
local function SendFingerprint()
    if not (Sharing() and Channel()) then return end
    local hex, n = Fingerprint(myQuests)
    Send("F^" .. hex .. "^" .. n .. "^" .. CompletedInfo().hex)   -- 3rd: fingerprint of everything I've completed
end

-- Send my whole completed-quests list (several messages), when a teammate asks for it.
local function SendCompleted()
    if not (Sharing() and Channel()) then return end
    compCache.dirty = true
    local info = CompletedInfo()
    if #info.ids == 0 then return end
    local data = EncodeIds(info.ids)
    local CHUNK = 200
    local parts = math.ceil(#data / CHUNK)
    for p = 1, parts do
        Send(("K^%d^%s^%d^%d^%s"):format(#info.ids, info.hex, p, parts, data:sub((p - 1) * CHUNK + 1, p * CHUNK)))
    end
end

-- Re-reads my quest log; when sharing, sends only what changed since last time.
local function UpdateMine()
    local quests, collapsed = Snapshot()
    -- A quest that vanished because its header got collapsed is still in the log: keep it.
    for id, old in pairs(myQuests) do
        if not quests[id] and old.header and collapsed[old.header] then quests[id] = old end
    end
    if Sharing() and Channel() then
        local changed = {}
        for id, q in pairs(quests) do
            local rec = EncodeRecord(id, q)
            if lastSent[id] ~= rec then lastSent[id] = rec; changed[#changed + 1] = id end
        end
        SendQuests(changed, quests)
        for id in pairs(lastSent) do
            if not quests[id] then lastSent[id] = nil; compCache.dirty = true; Send("R^" .. id) end   -- it may have been turned in
        end
    end
    myQuests = quests
    for id, q in pairs(quests) do Track(id, q.title) end
    local count = 0
    for _ in pairs(quests) do count = count + 1 end
    if count ~= lastCount then SendProfile() end   -- my quest log filled up or emptied
    Later("done", 3, function() ReportDone() end)
    Later("fp", 1, function() SendFingerprint() end)   -- tell teammates what my list now looks like
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
    stats.full = stats.full + 1
    -- The full list replaces any quest messages still waiting to go out.
    for i = #queue, 1, -1 do
        if queue[i]:find("^[QRCDPEV]") then table.remove(queue, i) end
    end
    wipe(lastSent)
    wipe(sentDone)
    Send("C^" .. ns.version)
    SendProfile()
    UpdateMine()
    ReportDone()
    Send("E")   -- end of my list: teammates show it (and everyone else's) all at once
    SendFingerprint()
end

local function SayHello()
    if Sharing() then stats.hello = stats.hello + 1; Send("H^" .. PROTOCOL .. "^" .. ns.version) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function ShortName(sender)
    if Ambiguate then return Ambiguate(sender, "none") end
    return sender
end

-- Is this name me? Handles "Name-Realm" too (my own messages come back to me, and on a connected
-- realm they can carry the realm, which would otherwise list me as one of my own teammates).
local function Norm(s) return (tostring(s or ""):lower():gsub("[%s%-'_]", "")) end

local function IsMe(name)
    if not name or name == "" then return false end
    local me = UnitName("player") or ""
    if name == me or name:match("^([^%-]+)") == me then return true end
    local n, m = Norm(name), Norm(me)
    if m == "" then return false end
    if n == m then return true end
    if GetUnitName and n == Norm(GetUnitName("player", true)) then return true end
    -- "Name" followed by (part of) my realm name, however the game spelled the separator or cut it short
    local realm = Norm((GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()))
    if n:sub(1, #m) == m then
        local rest = n:sub(#m + 1)
        if rest == "" or (realm ~= "" and realm:sub(1, #rest) == rest) then return true end
    end
    return false
end

-- How my own name looks when my messages come back to me (this client can show a longer name than
-- UnitName gives, e.g. "Skade Stormr" for "Skade"). Learned from the first echo; used wherever my name is shown.
local myNetName
local function MyName()
    local n = myNetName or UnitName("player") or "?"
    return (n:gsub("%-", " "))
end

-- Full lists that are still arriving (`incoming`, declared at the top): who -> { m = the new member data,
-- complete = true once their "E" came and every quest text they needed arrived }.
-- Nothing is shown from them until every list in progress is complete (or SYNC_TIMEOUT seconds pass).
local SYNC_TIMEOUT = 12
local ApplyIncoming

-- "Syncing..." is shown from the moment I ask the group to resend until their lists have landed
-- (or 8 s have passed with no answer), so a window that hasn't heard back yet never looks "in sync".
local syncWait = 0
local synced = false   -- the last sync finished and nothing has happened since that would need another
local function IsSyncing() return next(incoming) ~= nil or GetTime() < syncWait end
local function HasLive()   -- is anyone here whose quests I could be in sync with?
    for _, m in pairs(members) do if not m.ghost then return true end end
    return false
end
local function StartSync()
    syncWait = GetTime() + 8
    synced = false
    C_Timer.After(8.2, function()
        if next(incoming) == nil and GetTime() >= syncWait then synced = HasLive() end   -- nobody answered: nothing to be synced with
        RefreshWindow()
    end)
end

local function TryApply()
    for _, p in pairs(incoming) do
        if not p.complete then return end
    end
    ApplyIncoming()
end

ApplyIncoming = function()
    if next(incoming) == nil then return end
    stats.apply = stats.apply + 1
    local applied = {}
    for who, p in pairs(incoming) do
        local old = members[who]
        if old and old.heard then p.m.heard = math.max(p.m.heard or 0, old.heard) end
        members[who] = p.m
        incoming[who] = nil
        applied[#applied + 1] = who
    end
    syncWait = 0
    synced = true
    SyncGhosts()                          -- people who are back no longer need their saved copy shown
    for _, who in ipairs(applied) do CheckFingerprint(who) end   -- does what I now hold match what they announced?
    Later("remember", 3, function() RememberAll() end)
    RefreshWindow()
end

-- The wording of a quest just arrived: rebuild every stored copy of that quest that was waiting for it,
-- and let any list that was held up for it finish.
local function RefreshQuestText(id)
    local function Rebuild(m)
        local q = m.quests[id]
        if q and q.raw then m.quests[id] = (BuildQuest(id, q.state, q.raw)) end
    end
    for _, m in pairs(members) do Rebuild(m) end
    for _, p in pairs(incoming) do
        Rebuild(p.m)
        p.need[id] = nil
        if p.gotE and next(p.need) == nil then p.complete = true end
    end
    TryApply()
    if next(incoming) == nil then Later("window", 0.2, function() RefreshWindow() end) end
end

-- A teammate's quest whose wording I don't have: remember to ask.
local function NeedText(who, id)
    wanted[id] = true
    if incoming[who] then incoming[who].need[id] = true end
end

-- Ask the group for the wording of every quest in `wanted` (packed into as few messages as fit).
local function FlushNeeds()
    local ids = {}
    for id in pairs(wanted) do
        if not askedAt[id] or GetTime() - askedAt[id] > 15 then ids[#ids + 1] = id end
    end
    if #ids == 0 then return end
    table.sort(ids)
    local batch, len = {}, 2
    local function Out()
        if #batch > 0 then Send("N^" .. table.concat(batch, ",")) end
        batch, len = {}, 2
    end
    for _, id in ipairs(ids) do
        askedAt[id] = GetTime()
        local s = tostring(id)
        if len + #s + 1 > MAX_MSG - 2 then Out() end
        batch[#batch + 1] = s
        len = len + #s + 1
    end
    Out()
end

-- Teammates on a P13Tweaks older than 0.6.2 never send the end-of-list marker. Treat a list as
-- complete once nothing more has arrived from that teammate for 3 seconds (the sender's messages
-- come at most ~1.1 s apart), so they don't hold everyone up until the long timeout.
local CheckQuiet
CheckQuiet = function()
    local now = GetTime()
    local stillWaiting = false
    for _, p in pairs(incoming) do
        if not p.complete then
            if now - (p.last or 0) >= 3 then p.complete = true else stillWaiting = true end
        end
    end
    if stillWaiting then Later("quiet", 1, CheckQuiet) end
    TryApply()
end

-- Does my copy of a teammate's quest log match the fingerprint they announced? If not (even after a short wait,
-- in case a change was still on its way), ask them to resend their list. This is what keeps everyone in sync
-- without anyone pressing anything.
CheckFingerprint = function(who)
    local f, m = lastF[who], members[who]
    if not f or not m or m.ghost or m.demo or incoming[who] or m.legacy then return end
    if Fingerprint(m.quests) == f.hex then
        if m.sync ~= true then m.sync = true; Later("window", 0.2, function() RefreshWindow() end) end
        return
    end
    m.sync = false
    Later("window", 0.2, function() RefreshWindow() end)
    Later("fpcheck:" .. who, 3, function()
        local f2, m2 = lastF[who], members[who]
        if not f2 or not m2 or m2.ghost or incoming[who] then return end
        if Fingerprint(m2.quests) == f2.hex then
            m2.sync = true
            RefreshWindow()
        elseif not askedY[who] or GetTime() - askedY[who] > 20 then
            askedY[who] = GetTime()
            Send("Y^" .. who)   -- "please resend your list"
        end
    end)
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
    if IsMe(who) or IsMe(sender) then
        if not myNetName or #who > #myNetName then myNetName = who end   -- learn how my name is spelled
        return
    end
    local kind = msg:sub(1, 1)
    stats.msg[kind] = (stats.msg[kind] or 0) + 1
    local m = members[who]
    if m and m.ghost and kind ~= "F" then members[who] = nil; m = nil end   -- they're back: live data replaces the saved copy
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
        -- A full list is starting. Collect it on the side and show it only once it's complete
        -- (and everyone else's is), so the window changes once instead of piece by piece.
        local ver = msg:match("^C%^(.+)$") or (m and m.version)
        incoming[who] = { complete = false, need = {},
            -- (their finished-quests set and its hash carry over: a new quest list doesn't change what they've completed)
            m = { quests = {}, done = (m and m.done) or {}, doneHash = m and m.doneHash, protocol = m and m.protocol, version = ver } }
        CheckVersion(who, ver)
        Later("applyTimeout", SYNC_TIMEOUT, ApplyIncoming)   -- never wait forever on a teammate who doesn't finish
        Later("window", 0.2, function() RefreshWindow() end) -- shows "Syncing..."
    elseif kind == "E" then
        local p = incoming[who]
        if p then
            p.gotE = true
            if next(p.need) then
                FlushNeeds()   -- some quests' wording is unknown: ask, and finish when it arrives (or after 3 s of quiet)
            else
                p.complete = true
                TryApply()
            end
        end
    elseif kind == "V" then
        -- Compact quests: id:state:objectives, several per message
        local t = (incoming[who] and incoming[who].m) or m
        if not t then t = { quests = {} }; members[who] = t end
        t.done = t.done or {}
        for rec in msg:sub(3):gmatch("[^;]+") do
            local sid, state, objs = rec:match("^(%d+):(%-?%d+):(.*)$")
            if sid then
                local id = tonumber(sid)
                local q, known = BuildQuest(id, tonumber(state) or 0, objs)
                t.quests[id] = q
                t.done[id] = nil
                Track(id, q.title)
                if not known then NeedText(who, id) end
            end
        end
        if not incoming[who] and next(wanted) then Later("needtext", 0.5, FlushNeeds) end
        Later("done", 2, function() ReportDone() end)
    elseif kind == "N" then
        -- A teammate doesn't know the wording of these quests: send it for the ones I have
        local sent = 0
        for sid in msg:sub(3):gmatch("%d+") do
            local id = tonumber(sid)
            local q = myQuests[id]
            if q and sent < 30 and (not sentText[id] or GetTime() - sentText[id] > 20) then
                sentText[id] = GetTime()
                sent = sent + 1
                Send(EncodeText(id, q))
            end
        end
    elseif kind == "T" then
        local sid, title, tplStr = msg:match("^T%^(%d+)%^([^%^]*)%^?(.*)$")
        if sid then
            local id = tonumber(sid)
            local tpl = {}
            for part in tplStr:gmatch("[^~]+") do tpl[#tpl + 1] = part end
            TextCache()[id] = { title = title, tpl = tpl }
            wanted[id] = nil
            RefreshQuestText(id)
        end
    elseif kind == "X" then
        members[who] = nil
        incoming[who] = nil
    elseif kind == "Q" then
        local id, q = Decode(msg)
        if id then
            local t = (incoming[who] and incoming[who].m) or m
            if not t then t = { quests = {} }; members[who] = t end
            t.quests[id] = q
            t.done = t.done or {}
            t.done[id] = nil
            t.legacy = true                  -- their list came in the old format: its fingerprint can't be compared reliably
            CacheText(id, q.title, q.objs)   -- an old-format message carries the wording: keep it
            Track(id, q.title)
            Later("done", 2, function() ReportDone() end)   -- if I've finished it, say so
        end
    elseif kind == "P" then
        local lvl, race, class, n = msg:match("^P%^(%d+)%^(%d+)%^(%d+)%^(%d+)")
        if lvl then
            local t = (incoming[who] and incoming[who].m) or m
            if not t then t = { quests = {} }; members[who] = t end
            t.level, t.race, t.class, t.numQuests = tonumber(lvl), tonumber(race), tonumber(class), tonumber(n)
        end
    elseif kind == "F" then
        -- a teammate's fingerprint: compare with my copy of their quests
        local hex, n, chex = msg:match("^F%^(%x+)%^(%d+)%^?(%x*)")
        if hex then
            lastF[who] = { hex = hex, n = tonumber(n), at = GetTime(), c = chex ~= "" and chex or nil }
            if not m or m.ghost then
                -- I have no live copy of them at all: ask for their list
                if not incoming[who] and (not askedY[who] or GetTime() - askedY[who] > 20) then
                    askedY[who] = GetTime()
                    Send("Y^" .. who)
                end
            else
                CheckFingerprint(who)
                -- their completed-quests list: do I have the current one? (3rd field; "00000000" = they've completed nothing)
                if chex ~= "" and chex ~= "00000000" and m.doneHash ~= chex
                    and (not askedZ[who] or GetTime() - askedZ[who] > 60) then
                    askedZ[who] = GetTime()
                    Send("Z^" .. who)
                end
            end
        end
    elseif kind == "Z" then
        -- "<name>, please send everything you've completed": it's me
        if IsMe(msg:sub(3)) then Later("sendK", 1, SendCompleted) end
    elseif kind == "K" then
        -- a piece of a teammate's completed-quests list
        local cnt, chex, part, parts, data = msg:match("^K%^(%d+)%^(%x+)%^(%d+)%^(%d+)%^(.*)$")
        part, parts, cnt = tonumber(part), tonumber(parts), tonumber(cnt)
        if cnt and part and parts and part >= 1 and part <= parts and parts <= 60 and cnt <= 12000 then
            local p = doneParts[who]
            if not p or p.hex ~= chex or p.parts ~= parts then
                p = { hex = chex, parts = parts, got = {}, cnt = cnt }
                doneParts[who] = p
            end
            p.got[part] = data
            local have = 0
            for _ in pairs(p.got) do have = have + 1 end
            if have == parts then
                doneParts[who] = nil
                local set = DecodeIds(table.concat(p.got))
                local t = (incoming[who] and incoming[who].m) or m
                if not t then t = { quests = {} }; members[who] = t end
                if set then
                    for id in pairs(t.done or {}) do set[id] = true end   -- keep any single "finished" reports too
                    t.done = set
                    t.doneHash = chex
                    candDirtyFlag.v = true
                    Later("remember", 5, function() RememberAll() end)
                end
            end
        end
    elseif kind == "Y" then
        -- "<name>, please resend your list": it's me
        if IsMe(msg:sub(3)) then Later("full", 1, SendFull) end
    elseif kind == "D" then
        local id = tonumber(msg:match("^D%^(%d+)"))
        if id then
            local t = (incoming[who] and incoming[who].m) or m
            if not t then t = { quests = {} }; members[who] = t end
            t.done = t.done or {}
            t.done[id] = true
            -- a quest I have in my log that this teammate has already finished: say so once
            if myQuests[id] and not noticed[who .. ":" .. id] then
                noticed[who .. ":" .. id] = true
                ns:Print(("%s has already finished \"%s\" - you have it in your quest log."):format(who, myQuests[id].title or "that quest"))
            end
        end
    elseif kind == "R" then
        local id = tonumber(msg:match("^R%^(%d+)"))
        local t = (incoming[who] and incoming[who].m) or m
        if t and id then t.quests[id] = nil end
    end
    local now = GetTime()   -- for "Ask again": did they answer?
    if members[who] then members[who].heard = now end
    if incoming[who] then
        incoming[who].m.heard = now
        incoming[who].last = now
        Later("quiet", 3.2, CheckQuiet)   -- an older P13Tweaks never says "end of list"
    end
    Later("remember", 5, function() RememberAll() end)   -- keep the saved "last known" copy current
    Later("ghosts", 1, function() SyncGhosts() end)
    -- While a list is still arriving the window waits; it refreshes once, when everything has landed.
    if next(incoming) == nil then Later("window", 0.2, function() RefreshWindow() end) end
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
            -- Just the name, never "Name-Realm": the realm part can appear and disappear between calls
            -- (it loads late), which used to look like people joining and leaving over and over.
            local name = UnitName(unit)
            if name then t[name] = true end
        end
    end
    return t
end

-- Does a stored teammate name (however it was spelled: "Ann", "Ann-Realm", "Ann Realm") belong to someone in the group now?
local function KeyInGroup(key)
    local k = Norm(key)
    local myRealm = Norm((GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()))
    local raid = IsInRaid()
    for i = 1, (GetNumGroupMembers() or 0) do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local name, realm = UnitName(unit)
            local n = Norm(name)
            if n ~= "" then
                local r = (realm and realm ~= "") and Norm(realm) or myRealm
                if k == n or k == n .. r then return true, name end   -- second result: their plain in-game name
                if k:sub(1, #n) == n then
                    local rest = k:sub(#n + 1)
                    if rest ~= "" and r:sub(1, #rest) == rest then return true, name end
                end
            end
        end
    end
    return false
end

-- The stored data for a group member by their plain name, whichever way it was keyed.
local function FindMember(name, liveOnly)
    if members[name] and not (liveOnly and members[name].ghost) then return members[name], name end
    local n = Norm(name)
    for key, m in pairs(members) do
        local k = Norm(key)
        if (k == n or k:sub(1, #n) == n) and not (liveOnly and m.ghost) then return m, key end
    end
end

---------------------------------------------------------------------------
-- Last known quests of teammates who aren't here right now
---------------------------------------------------------------------------
-- Each teammate's quests are saved (P13TweaksDB.lastKnown) as they play. When they're offline or have left the group
-- they still show in the quests window, tagged "(last known 2 h ago)", so you can see what they've done and catch up.

local function Remembering() return ns:Get("questShareRemember") end

local function SavedKnown()
    P13TweaksDB.lastKnown = P13TweaksDB.lastKnown or {}
    return P13TweaksDB.lastKnown
end

-- "5 min ago", "3 h ago", "2 days ago"
local function Ago(t)
    local d = time() - (t or 0)
    if d < 90 then return "just now" end
    if d < 5400 then return math.floor(d / 60 + 0.5) .. " min ago" end
    if d < 129600 then return math.floor(d / 3600 + 0.5) .. " h ago" end
    return math.floor(d / 86400 + 0.5) .. " days ago"
end

local function GhostTag(m) return " |cff808080(last known " .. Ago(m.lastSeen) .. ")|r" end

-- Saves (a reference to) every live teammate's data. The tables keep updating while the teammate is here and stop
-- when they leave, so what's saved is their last known state.
RememberAll = function()
    if not Remembering() then return end
    local saved = SavedKnown()
    for key, m in pairs(members) do
        if not m.demo and not m.ghost and next(m.quests) ~= nil then   -- (an empty list may just mean "not sent yet")
            saved[key] = { t = time(), version = m.version, level = m.level, race = m.race, class = m.class,
                numQuests = m.numQuests, quests = m.quests, done = m.done or {} }
        end
    end
end

-- Forget old entries: older than 30 days, or beyond the 12 most recent.
local function PruneKnown()
    local saved = SavedKnown()
    local cutoff = time() - 30 * 86400
    local list = {}
    for key, s in pairs(saved) do
        if type(s) ~= "table" or type(s.quests) ~= "table" or (s.t or 0) < cutoff then
            saved[key] = nil
        else
            list[#list + 1] = { key = key, t = s.t or 0 }
        end
    end
    if #list > 12 then
        table.sort(list, function(a, b) return a.t > b.t end)
        for i = 13, #list do saved[list[i].key] = nil end
    end
end

-- Puts saved teammates who have no live data now into `members`, flagged ghost = true (and removes ghosts that
-- aren't needed any more). Ghosts show in the windows but are never offered quests to share, never asked, never counted.
SyncGhosts = function()
    for key, m in pairs(members) do if m.ghost then members[key] = nil end end
    if not (Remembering() and Sharing()) or not Channel() then return end
    for key, s in pairs(SavedKnown()) do
        -- only people who are in the group right now (an offline party member); anyone who left isn't shown
        if type(s) == "table" and type(s.quests) == "table" and not IsMe(key) and KeyInGroup(key) then
            local n, live = Norm(key), false
            for k2, m in pairs(members) do
                local kk = Norm(k2)
                if not m.ghost and (kk == n or kk:sub(1, #n) == n or n:sub(1, #kk) == kk) then live = true; break end
            end
            if not live then
                members[key] = { quests = s.quests, done = s.done or {}, ghost = true, lastSeen = s.t, version = s.version,
                    level = s.level, race = s.race, class = s.class, numQuests = s.numQuests }
                -- count their quests / finished quests as seen in the group (so "Catch up" and the map hints can use them)
                for id, q in pairs(s.quests) do Track(id, q.title) end
                for id in pairs(s.done or {}) do if not seen[id] then seen[id] = true end end
            end
        end
    end
end

local function OnRoster()
    if not Channel() then
        wipe(roster); wipe(queue); wipe(lastSent); wipe(sentDone); wipe(seen); wipe(incoming)
        RememberAll()   -- keep what we last knew of them before they disappear from the group
        for name, m in pairs(members) do if not m.demo then members[name] = nil end end
        SyncGhosts()    -- ...and show it, tagged "last known"
        RefreshWindow()
        return
    end
    local now = GroupNames()
    RememberAll()
    for name, m in pairs(members) do
        if not m.demo and not m.ghost and not KeyInGroup(name) then members[name] = nil end   -- left the group
    end
    SyncGhosts()
    for name in pairs(incoming) do
        if not KeyInGroup(name) then incoming[name] = nil end
    end
    local someoneNew = false
    for name in pairs(now) do if not roster[name] then someoneNew = true end end
    roster = now
    if someoneNew then
        stats.newcomer = stats.newcomer + 1
        StartSync()
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

-- "quest" (by quest), "compare" (side by side), "plan" (what to do to get in sync), "player" (by player)
local function ViewMode()
    local v = ns:Get("questShareView")
    return (v == "player" or v == "compare" or v == "plan") and v or "quest"
end
local NEXT_VIEW = { quest = "compare", compare = "plan", plan = "player", player = "quest" }
local VIEW_LABEL = { quest = "View: by quest", compare = "View: side by side", plan = "View: sync plan", player = "View: by player" }

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

local function MaxQuests()
    return (C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept())
        or MAX_QUESTLOG_QUESTS or 20
end

-- Reasons a teammate couldn't accept a quest I share with them (empty = nothing known to stop them).
-- Needs the teammate to have sent their level/race/class (a recent P13Tweaks) and QuestieDB for the quest data.
local function WhyNot(m, name, id)
    local reasons, refs = {}, {}
    if m.level and ns.WhyCantTake then
        reasons, refs = ns.WhyCantTake(id, {
            name = name, level = m.level, raceId = m.race, classId = m.class, checkPrereqs = true,
            done = function(i) return m.done and m.done[i] end,
            has = function(i) return m.quests[i] ~= nil end,
        })
        reasons, refs = reasons or {}, refs or {}
    end
    if m.numQuests and m.numQuests >= MaxQuests() then
        table.insert(reasons, name .. "'s quest log is full")
    end
    return reasons, refs   -- refs: quest ids they'd need to find first (clickable in the sync plan)
end

-- Does anyone with P13Tweaks in the group still need this quest (haven't got it, haven't finished it,
-- and could actually accept it)?
local function NeededBySomeone(id)
    for name, m in pairs(members) do
        if not m.demo and not m.ghost and not m.quests[id] and not (m.done and m.done[id]) and #WhyNot(m, name, id) == 0 then
            return true
        end
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
    StartSync()
    lastCheck = { "|cff808080Checking...|r" }
    RefreshWindow()
    SayHello()
    ns:Print("Asking your group...")
    C_Timer.After(9, function()   -- their list starts ~2 s after I ask; an older P13Tweaks is applied ~3 s after its last message
        local names = {}
        for name in pairs(GroupNames()) do table.insert(names, name) end
        table.sort(names)
        local lines = {}
        for _, name in ipairs(names) do
            local m = FindMember(name, true)   -- live data only (stored under whichever spelling their messages used)
            local line
            if m and m.heard and m.heard >= t0 then
                local n = 0
                for _ in pairs(m.quests) do n = n + 1 end
                line = ("|cff40ff40updated|r - %d quest%s%s"):format(n, n == 1 and "" or "s", VerTag(m.version))
                if not m.version then
                    line = line .. " |cffff6040(older P13Tweaks - update it for the newest features)|r"
                elseif m.version ~= ns.version then
                    line = line .. " |cffff6040(different version)|r"
                end
            elseif m then
                line = "|cffffd200no answer|r - still showing what they sent before"
            else
                line = "|cffff6040no answer|r - no P13Tweaks, quest sharing turned off, or a version from before quest sharing"
            end
            table.insert(lines, NameColor(name) .. name .. "|r: " .. line)
        end
        if #lines == 0 then lines[1] = "Nobody else is in your group." end
        lastCheck = lines
        for _, l in ipairs(lines) do ns:Print(l) end
        RefreshWindow()
    end)
end

-- Tracks one of my quests in the game (objective tracker + the highlighted tracked quest).
local function SelectInGame(id)
    if not myQuests[id] then ns:Print("That quest isn't in your quest log."); return end
    local index
    for i = 1, NumEntries() do
        local _, isHeader, _, _, qid = Entry(i)
        if not isHeader and qid == id then index = i; break end
    end
    -- Track it (no quest log or map window is opened): put it on the objective tracker, and make it
    -- THE tracked quest (the highlighted one) where the game has that.
    local done = false
    if C_QuestLog and C_QuestLog.AddQuestWatch then
        pcall(C_QuestLog.AddQuestWatch, id)
        done = true
    elseif AddQuestWatch and index then
        pcall(AddQuestWatch, index)
        if QuestWatch_Update then pcall(QuestWatch_Update) end
        done = true
    end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
        pcall(C_SuperTrack.SetSuperTrackedQuestID, id)
        done = true
    end
    if done then
        ns:Print("Tracking: " .. (myQuests[id].title or "quest"))
    else
        ns:Print("Couldn't track it - its zone may be collapsed in your quest log. Expand it and try again.")
    end
end

local function QuestButton(i)
    if btns[i] then return btns[i] end
    local b = CreateFrame("Button", nil, content)
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    b:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.12)
    b:SetScript("OnClick", function(self)
        if self.guide then   -- a quest I don't have: how do I get it?
            ns.ShowQuestGuide(self.guide, self.guideTitle, self.guideWho and { forName = self.guideWho } or nil)
            return
        end
        -- one of my quests: show it in my quest log; Shift-click (or a "Share these" line) shares it instead
        if not (self.share or IsShiftKeyDown()) then
            SelectInGame(self.questId)
            return
        end
        local ok, why = PushQuest(self.questId)
        if ok then ns:Print("Shared \"" .. (myQuests[self.questId] and myQuests[self.questId].title or "quest") .. "\" with your group.")
        else ns:Print("Couldn't share it: " .. why .. ".") end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.guide then
            GameTooltip:SetText(self.guideWho and "Click to see where this quest starts" or "Click to see how to get this quest", 1, 1, 1)
        elseif self.share then
            GameTooltip:SetText("Click to share this quest with your group", 1, 1, 1)
        else
            GameTooltip:SetText("Click to track this quest", 1, 1, 1)
            GameTooltip:AddLine("Shift-click to share it with your group", 0.8, 0.8, 0.8)
        end
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

    -- Syncing is automatic; this just shows where it stands ("Syncing..." / "Synced").
    local status = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("TOPRIGHT", -14, -36)
    status:SetJustifyH("RIGHT")
    win.syncText = status

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

    win:Hide()   -- a new frame starts shown; callers show it (otherwise the first toggle would hide it)
    -- Opening the window just does a quick check: announce my fingerprint, and compare the ones I already have.
    -- Anything that doesn't match is re-sent automatically (see CheckFingerprint); nobody has to press anything.
    win:SetScript("OnShow", function()
        if Sharing() and Channel() then
            SendFingerprint()
            for who in pairs(members) do CheckFingerprint(who) end
        end
        RefreshWindow()
    end)
end

-- A class quest I can't take (my class isn't in its class mask). Teammates' class quests are only followed
-- when they're also mine, i.e. when we're the same class. Needs QuestieDB; without it nothing is hidden.
local function ClassLocked(id)
    local lib = _G.LibQuestieDB
    if not (lib and lib.Quest and lib.Quest.Get) then return false end
    local ok, mask = pcall(lib.Quest.Get, id, "requiredClasses")
    if not ok or type(mask) ~= "number" or mask <= 0 then return false end
    local _, _, cid = UnitClass("player")
    return (cid and cid <= 31 and bit.band(mask, bit.lshift(1, cid - 1)) == 0) and true or false
end

-- a teammate's quests without the other classes' class quests
local function Visible(m)
    local src = m.quests or {}
    if m.demo then return src end
    local t = {}
    for id, q in pairs(src) do if not ClassLocked(id) then t[id] = q end end
    return t
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

-- First line of the by-quest and sync-plan views: everyone in the group who shares quests, each once
-- (you first, then teammates alphabetically), with their P13Tweaks version.
local function PlayersLine(out, names)
    local seenName, items = {}, {}
    local function Add(name, label, follow)
        if not seenName[name] then seenName[name] = true; items[#items + 1] = { label = label, follow = follow } end
    end
    local me = UnitName("player") or "?"
    Add(me, NameColor("player") .. MyName() .. "|r" .. VerTag(ns.version), nil)   -- can't follow yourself
    for _, name in ipairs(names) do
        if not IsMe(name) then
            local pm = members[name]
            local ghost = pm and pm.ghost
            Add(name, NameColor(name) .. name .. "|r" .. (ghost and " |cff808080(offline)|r" or VerTag(pm and pm.version)),
                (not ghost) and name or nil)
        end
    end
    -- two names per row; Shift-click a teammate's name to follow them (see ApplyFollowButtons)
    local LABEL, CW, PER_ROW = 60, 140, 2
    for i = 1, #items, PER_ROW do
        local row = { i == 1 and "|cff808080Players:|r" or "", 0, i == 1 and 0 or 2, cells = {}, titleW = LABEL, nowrap = true }
        for j = i, math.min(i + PER_ROW - 1, #items) do
            row.cells[#row.cells + 1] = { x = LABEL + (j - i) * CW, w = CW, text = items[j].label, follow = items[j].follow }
        end
        table.insert(out, row)
    end
end

-- Quests a teammate has completed that I haven't and could reasonably do now: their level needs are met and they're not far
-- below my level. A teammate's completed list can be thousands long, so QuestieDB is asked about at most 80 new quests per
-- call and the rest are picked up on the next ones (the window / map refresh again shortly). Newest-level first, at most 40.
-- Each entry: { id, ql (quest level) }.
local candCache, candAt = {}, -100
local levelDone = {}   -- quest id -> its QuestieDB level info, or false if QuestieDB doesn't know it
local function DoneCandidates()
    if not candDirtyFlag.v and GetTime() - candAt < 5 then return candCache end
    candDirtyFlag.v = false
    candAt = GetTime()
    if not (ns.QuestLevelInfo) then return candCache end
    local myLevel = UnitLevel("player") or 1
    local seenId, list, budget, more = {}, {}, 80, false
    for _, m in pairs(members) do
        if not m.demo then
            for id in pairs(m.done or {}) do
                if not seenId[id] and not myQuests[id] and not Completed(id) then
                    seenId[id] = true
                    local info
                    if levelDone[id] ~= nil then
                        info = levelDone[id] or nil
                    elseif budget > 0 then
                        budget = budget - 1
                        info = ns.QuestLevelInfo(id)
                        levelDone[id] = info or false
                    else
                        more = true   -- over budget for this call: the rest next time
                    end
                    if info and info.req <= myLevel and info.ql >= myLevel - 10 then
                        list[#list + 1] = { id = id, ql = info.ql }
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) if a.ql ~= b.ql then return a.ql > b.ql end return a.id < b.id end)
    for i = #list, 41, -1 do list[i] = nil end
    candCache = list
    if more then
        candDirtyFlag.v = true
        Later("cands", 0.3, function() RefreshWindow() end)   -- looks again (and so do the map hints on their next refresh)
    end
    return list
end

-- Teammates who have already FINISHED quest `id` (and don't hold it any more), while I haven't - or nil.
-- Used to flag quests in my log that someone else has already done.
local function FinishedBy(id)
    if Completed(id) or ClassLocked(id) then return nil end
    local names = {}
    for key, m in pairs(members) do
        if not m.demo and not (m.quests and m.quests[id]) and m.done and m.done[id] then names[#names + 1] = key end
    end
    table.sort(names)
    return #names > 0 and names or nil
end

local function FinishedBadge(id)
    local n = FinishedBy(id)
    return n and (" |cff40c0ff- finished by " .. table.concat(n, ", ") .. "|r") or ""
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
        table.insert(players, { name = name, color = NameColor(name), quests = Visible(m),
            isDone = function(id) return m.done and m.done[id] end })
    end
    if #names == 0 then return end
    PlayersLine(out, names)

    local ids, title = {}, {}
    for _, p in ipairs(players) do
        for id, q in pairs(p.quests) do
            if not title[id] then title[id] = q.title or seen[id] or "?"; table.insert(ids, id) end
        end
    end
    table.sort(ids, function(a, b) return title[a] < title[b] end)

    -- Order by quest chain: a quest sits under the nearest earlier quest of the chain that is also in this list
    -- (via QuestieDB's prerequisites), so a chain reads top to bottom, each step indented under the one before.
    local depth = {}
    do
        local inSet = {}
        for _, id in ipairs(ids) do inSet[id] = true end
        local lib = _G.LibQuestieDB
        local function Pre(id)
            local out = {}
            if not (lib and lib.Quest and lib.Quest.Get) then return out end
            for _, f in ipairs({ "preQuestSingle", "preQuestGroup", "parentQuest" }) do
                local ok, v = pcall(lib.Quest.Get, id, f)
                if ok then
                    if type(v) == "number" and v > 0 then out[#out + 1] = v
                    elseif type(v) == "table" then
                        for _, x in ipairs(v) do if type(x) == "number" and x > 0 then out[#out + 1] = x end end
                    end
                end
            end
            return out
        end
        local parent = {}
        for _, id in ipairs(ids) do
            local frontier, visited = { id }, { [id] = true }
            for _ = 1, 8 do
                local nxt = {}
                for _, cur in ipairs(frontier) do
                    for _, p in ipairs(Pre(cur)) do
                        if not visited[p] then
                            visited[p] = true
                            if inSet[p] and not parent[id] then parent[id] = p end
                            nxt[#nxt + 1] = p
                        end
                    end
                end
                if parent[id] or #nxt == 0 then break end
                frontier = nxt
            end
        end
        local kids = {}
        for _, id in ipairs(ids) do
            local p = parent[id]
            if p then kids[p] = kids[p] or {}; table.insert(kids[p], id) end
        end
        local ordered, placed = {}, {}
        local function Walk(id, d)
            if placed[id] then return end
            placed[id] = true
            depth[id] = d
            ordered[#ordered + 1] = id
            for _, k in ipairs(kids[id] or {}) do Walk(k, math.min(d + 1, 6)) end
        end
        for _, id in ipairs(ids) do if not parent[id] then Walk(id, 0) end end
        for _, id in ipairs(ids) do Walk(id, 0) end   -- (anything left over, e.g. a prerequisite loop)
        ids = ordered
    end

    local missing = {}
    for name in pairs(GroupNames()) do if not FindMember(name, true) then table.insert(missing, name) end end
    table.sort(missing)
    table.insert(out, { "|cff808080Click one of your quests to track it (Shift-click shares it); click one you don't have to see how to get it.|r", 0, 2 })
    if #missing > 0 then
        table.insert(out, { "|cff808080No P13Tweaks (can't be shown): " .. table.concat(missing, ", ") .. "|r", 0, 2 })
    end
    if #ids == 0 then table.insert(out, { "|cff808080(nobody has any quests)|r", 0, 8 }) end

    for _, id in ipairs(ids) do
        local d = depth[id] or 0
        table.insert(out, { (d > 0 and "|cff808080\226\134\179|r " or "") .. "|cffffd200" .. title[id] .. "|r" .. FinishedBadge(id),
            d * 14, d > 0 and 5 or 10, myQuests[id] and id or nil, guide = (not myQuests[id]) and id or nil })
        for _, p in ipairs(players) do
            local q = p.quests[id]
            local status = q and Summary(q) or (p.isDone(id) and "|cff40c0ffalready completed|r") or "|cff808080not started|r"
            local pm = members[p.name]   -- nil for you
            local tag = pm and (pm.ghost and " |cff808080(offline)|r" or VerTag(pm.version)) or ""
            table.insert(out, { p.color .. p.name .. "|r" .. tag .. ": " .. status, 14 + d * 14, 1,
                follow = (pm and not pm.ghost) and p.name or nil })
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
        table.insert(out, { NameColor(name) .. name .. "|r" .. (m.ghost and GhostTag(m) or VerTag(m.version)),
            0, #out > 0 and 14 or 0, follow = (not m.ghost) and name or nil })
        local list = SortedQuests(Visible(m))
        if #list == 0 then table.insert(out, { "|cff808080(no quests)|r", 12, 2 }) end
        for _, e in ipairs(list) do
            local q = e.q
            local t = "|cffffd200" .. (q.title or "?") .. "|r"
            if q.state == 1 then t = t .. " |cff40ff40(ready to turn in)|r"
            elseif q.state == -1 then t = t .. " |cffff4040(failed)|r" end
            if myQuests[e.id] and not m.demo then t = t .. " |cff8fa8ff(you have it too)|r" end
            t = t .. FinishedBadge(e.id)
            table.insert(out, { t, 12, 4, myQuests[e.id] and e.id or nil, guide = (not myQuests[e.id]) and e.id or nil })
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
    -- Only teammates get a column (you're never listed); your own quests still make rows,
    -- so you can see where everyone else is on them.
    local players = {}
    local names = {}
    for name in pairs(members) do table.insert(names, name) end
    table.sort(names)
    if #names == 0 then return end
    for _, name in ipairs(names) do
        local m = members[name]
        table.insert(players, { name = name, color = NameColor(name), quests = Visible(m), version = m.version, ghost = m.ghost,
            isDone = function(id) return m.done and m.done[id] end })
    end
    local n = #players
    local gapX = CMP_TITLE + n * CMP_COL

    -- every quest anyone (including you) has
    local title, ids = {}, {}
    local sources = { myQuests }
    for _, p in ipairs(players) do sources[#sources + 1] = p.quests end
    for _, source in ipairs(sources) do
        for id, q in pairs(source) do
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
        table.insert(head.cells, { x = CMP_TITLE + (i - 1) * CMP_COL, w = CMP_COL, follow = (not p.ghost) and p.name or nil,
            text = p.color .. p.name .. "|r\n" .. (p.ghost and "|cff808080offline|r" or VerTag(p.version):gsub("^ ", "")) })
    end
    table.insert(head.cells, { x = gapX, w = CMP_GAP, text = "|cff808080gap|r" })
    table.insert(out, head)

    local shown = 0
    for _, r in ipairs(rows) do
        if r.differs or not diffOnly then
            shown = shown + 1
            local e = { (FinishedBy(r.id) and "|cff40c0ff[done]|r " or "") .. (r.differs and "|cffffd200" or "|cffa0a070") .. title[r.id] .. "|r", 0, 5,
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
    table.insert(out, { "|cff808080green = furthest along, amber = behind, - = not started. Click one of your quests to track it (Shift-click shares it), or one you don't have to see how to get it.|r", 0, 10 })
end

-- Sync plan: what to do so everyone ends up on the same quests, as short click-through lists.
--   Share these       quests you have that a teammate lacks (click = share with the group)
--   Get these         quests only teammates have (click = how to get it)
--   Ask a teammate    quests a teammate has that another teammate lacks, and you can't share
--   Catch up          quests everyone has but at different points
local function BuildPlan(out)
    local names = {}
    for name in pairs(members) do table.insert(names, name) end
    table.sort(names)
    if #names == 0 then return end
    PlayersLine(out, names)

    local players = { { me = true, quests = myQuests, isDone = Completed } }
    for _, name in ipairs(names) do
        local m = members[name]
        table.insert(players, { name = name, m = m, quests = Visible(m), ghost = m.ghost,
            isDone = function(id) return m.done and m.done[id] end })
    end
    -- your own character name (in your class colour) is used wherever the plan refers to you
    local myLabel = NameColor("player") .. MyName() .. "|r"
    local function Label(p)
        if p.me then return myLabel end
        return NameColor(p.name) .. p.name .. "|r" .. (p.ghost and " |cff808080(offline)|r" or "")
    end
    local function Labels(list)
        local t = {}
        for _, p in ipairs(list) do t[#t + 1] = Label(p) end
        return table.concat(t, ", ")
    end
    local function Others(list)   -- teammates who are here (offline ones can't be given or asked for anything)
        local t = {}
        for _, p in ipairs(list) do if not p.me and not p.ghost then t[#t + 1] = p end end
        return t
    end

    local title, ids = {}, {}
    for _, p in ipairs(players) do
        for id, q in pairs(p.quests) do
            if not title[id] then title[id] = q.title or seen[id] or "?"; table.insert(ids, id) end
        end
    end
    -- Quests a teammate has finished that I haven't, even if nobody has them in their log now
    -- (known from the "finished" reports, which cover every quest seen in the group and the quests before them).
    for id in pairs(seen) do
        if not title[id] and not Completed(id) and not ClassLocked(id) then
            local doneByMate = false
            for _, p in ipairs(players) do
                if not p.me and p.isDone(id) then doneByMate = true end
            end
            if doneByMate then
                title[id] = (type(seen[id]) == "string" and seen[id]) or (ns.QuestName and ns.QuestName(id)) or ("quest " .. id)
                table.insert(ids, id)
            end
        end
    end
    -- ...and the quests teammates have completed overall (their whole history, not just what's been seen in logs):
    -- the ones I could reasonably do now (see DoneCandidates)
    for _, c in ipairs(DoneCandidates()) do
        local id = c.id
        if not title[id] then
            title[id] = (type(seen[id]) == "string" and seen[id]) or (ns.QuestName and ns.QuestName(id)) or ("quest " .. id)
            table.insert(ids, id)
        end
    end
    table.sort(ids, function(a, b) return title[a] < title[b] end)

    local share, get, relay, catchUp, blocked = {}, {}, {}, {}, {}
    for _, id in ipairs(ids) do
        local holders, lackers, info = {}, {}, {}
        for _, p in ipairs(players) do
            local q = p.quests[id]
            if q then
                holders[#holders + 1] = p
                local text, score = CompareCell(q, false)
                info[p] = { text = text, score = score or 0 }
            elseif not p.isDone(id) then
                lackers[#lackers + 1] = p
            end
        end
        local mine = myQuests[id] ~= nil
        local lackMates, holdMates = Others(lackers), Others(holders)
        local meLacks = false
        for _, p in ipairs(lackers) do if p.me then meLacks = true end end
        local head = "|cffffd200" .. title[id] .. "|r"

        -- Only suggest sharing with teammates who could accept it; the rest go under "can't be shared yet".
        -- One indented line per blocked player under the quest; under it, a clickable line for each
        -- quest they'd have to find first (opens where that quest starts).
        local canMates, bsubs, blockedGuide = {}, {}, nil
        local function FindLines(refs, forName)
            local seenRef = {}
            for _, rid in ipairs(refs or {}) do
                if not seenRef[rid] and #bsubs < 40 then
                    seenRef[rid] = true
                    local rname = (myQuests[rid] and myQuests[rid].title) or (ns.QuestName and ns.QuestName(rid))
                    table.insert(bsubs, { text = "|cff40c0ff-> find: " .. (rname or ("quest " .. rid)) .. "|r |cff808080(click)|r",
                        indent = 40, guide = rid, who = forName or false })
                end
            end
        end

        -- my own blockers first (my name, then what I'd have to find), then the teammates'
        local myWhy, myRefs = {}, {}
        if meLacks and #holdMates > 0 and ns.WhyCantTake then myWhy, myRefs = ns.WhyCantTake(id) end
        myWhy, myRefs = myWhy or {}, myRefs or {}
        if #myWhy > 0 then
            table.insert(bsubs, myLabel .. "|cffff6040: " .. table.concat(myWhy, "; ") .. "|r")
            FindLines(myRefs, nil)
            blockedGuide = id   -- clicking the quest shows how to get it
        end
        for _, p in ipairs(lackMates) do
            local why, refs = WhyNot(p.m, p.name, id)
            if #why == 0 then
                canMates[#canMates + 1] = p
            elseif #holdMates > 0 or mine then
                table.insert(bsubs, Label(p) .. "|cffff6040: " .. table.concat(why, "; ") .. "|r")
                FindLines(refs, p.name)
            end
        end

        if mine and #canMates > 0 then
            table.insert(share, { head .. " |cff808080->|r " .. Labels(canMates), id = id, share = true })
        end
        if meLacks and #holdMates > 0 then
            if #myWhy == 0 then
                table.insert(get, { head .. " |cff808080- |r" .. Labels(holdMates)
                    .. " |cff808080has it: ask them to share it, or click to see how to get it|r", guide = id })
            end
        end
        if #bsubs > 0 then
            table.insert(blocked, { head, sub = bsubs, guide = blockedGuide })
        end
        if not mine and #canMates > 0 and #holdMates > 0 then
            table.insert(relay, { head .. " |cff808080-|r " .. Labels(holdMates)
                .. " |cff808080should share it with|r " .. Labels(canMates) })
        end
        -- A teammate has finished it and I haven't: catch up. Every player gets a line: finished / progress / not started.
        local mateDone = {}
        for _, p in ipairs(players) do
            if not p.me and not p.quests[id] and p.isDone(id) then mateDone[#mateDone + 1] = p end
        end
        local handled = false
        if #mateDone > 0 and not Completed(id) then
            handled = true
            local best = -1
            for _, p in ipairs(holders) do best = math.max(best, info[p].score) end
            local subs = {}
            for _, p in ipairs(players) do
                if p.quests[id] then
                    local isBehind = info[p].score < best - 0.001
                    table.insert(subs, Label(p) .. (isBehind and " |cffffa040" or " |cff40ff40") .. info[p].text .. "|r")
                elseif p.isDone(id) then
                    table.insert(subs, Label(p) .. " |cff40c0fffinished|r")
                else
                    table.insert(subs, Label(p) .. " |cff808080not started|r")
                end
            end
            table.insert(catchUp, { head, sub = subs, id = mine and id or nil, guide = (not mine) and id or nil })
        end
        if not handled and #holders >= 2 then
            local best, worst = -1, 2
            for _, p in ipairs(holders) do
                best = math.max(best, info[p].score); worst = math.min(worst, info[p].score)
            end
            if best - worst > 0.001 then
                -- one indented line per player under the quest
                local subs = {}
                for _, p in ipairs(holders) do
                    local isBehind = info[p].score < best - 0.001
                    table.insert(subs, Label(p) .. (isBehind and " |cffffa040" or " |cff40ff40") .. info[p].text .. "|r"
                        .. (isBehind and " |cff808080(behind)|r" or " |cff808080(ahead)|r"))
                end
                table.insert(catchUp, { head, sub = subs, id = mine and id or nil })   -- click = show it in my quest log
            end
        end
    end

    local function Section(titleText, list, gap)
        if #list == 0 then return false end
        table.insert(out, { titleText, 0, gap })
        for _, e in ipairs(list) do
            table.insert(out, { e[1], 8, 3, e.id, guide = e.guide, shareOnClick = e.share })
            for _, s in ipairs(e.sub or {}) do
                if type(s) == "table" then   -- a clickable line: opens where quest s.guide starts
                    table.insert(out, { s.text, s.indent or 24, 1, guide = s.guide, guideWho = s.who })
                else
                    table.insert(out, { s, 24, 1 })   -- e.g. one line per player under the quest
                end
            end
        end
        return true
    end
    local any = false
    any = Section("|cff40ff40Share these|r |cff808080(click one; they need to be close by, with room in their quest log)|r", share, 0) or any
    any = Section("|cff40c0ffGet these|r |cff808080(click one to see how)|r", get, any and 12 or 0) or any
    any = Section("|cffffa040Ask a teammate to share|r", relay, any and 12 or 0) or any
    any = Section("|cffff6040Can't be shared yet|r |cff808080(requirements not met)|r", blocked, any and 12 or 0) or any
    any = Section("|cffffa040Catch up|r |cff808080(a teammate is further along or has finished it)|r", catchUp, any and 12 or 0) or any
    if not any and not IsSyncing() then   -- don't claim "in sync" before the answers are in
        table.insert(out, { "|cff40ff40Everyone is on the same quests at the same point - nothing to do.|r", 0, 0 })
    end
    local missing = {}
    for name in pairs(GroupNames()) do if not FindMember(name, true) then table.insert(missing, name) end end
    table.sort(missing)
    if #missing > 0 then
        table.insert(out, { "|cff808080No P13Tweaks (can't be compared): " .. table.concat(missing, ", ") .. "|r", 0, 12 })
    end
end

-- Shift-click a teammate's name in this window to follow them. Following needs a secure button, and
-- secure buttons can only be moved / changed out of combat, so during combat they keep their last setup.
local fbtns = {}
local function ApplyFollowButtons(list)
    if InCombatLockdown() then return end
    local on = ns:Get("followClick")
    for i, f in ipairs(list) do
        local b = fbtns[i]
        if not b then
            b = CreateFrame("Button", nil, content, "SecureActionButtonTemplate")
            b:RegisterForClicks("AnyUp")
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Shift-click to follow " .. (self.followName or "?"), 1, 1, 1)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            fbtns[i] = b
        end
        local _, uname = KeyInGroup(f.key)   -- their plain in-game name, whichever way their messages spelled it
        uname = uname or f.key
        b.followName = uname
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", content, "TOPLEFT", f.x, -f.y)
        b:SetSize(math.max(20, f.w), math.max(10, f.h))
        b:SetAttribute("shift-type1", on and "macro" or nil)
        b:SetAttribute("shift-macrotext1", on and ("/follow " .. uname) or nil)
        b:SetShown(on and true or false)
    end
    for i = #list + 1, #fbtns do fbtns[i]:Hide() end
end

RefreshWindow = function()
    if not (win and win:IsShown()) then return end
    local mode = ViewMode()
    win.viewBtn:SetText(VIEW_LABEL[mode])
    -- Sync status (automatic): "Syncing..." while lists are arriving or a teammate's copy doesn't match their
    -- fingerprint yet, "Synced" once every teammate's copy matches. Empty when there's nobody to compare with.
    if win.syncText then
        local anyFalse, anyTrue = false, false
        for _, m in pairs(members) do
            if not m.ghost and not m.demo then
                if m.sync == false then anyFalse = true elseif m.sync then anyTrue = true end
            end
        end
        if IsSyncing() or anyFalse then
            win.syncText:SetText("|cffffd200Syncing...|r")
        elseif anyTrue then
            win.syncText:SetText("|cff40ff40Synced|r")
        else
            win.syncText:SetText("")
        end
    end
    win.diffBtn:SetShown(mode == "compare")
    win.diffBtn:SetText(ns:Get("questShareDiffOnly") and "Show: diffs" or "Show: all")

    -- The side-by-side view is as wide as it needs to be; the others use the normal width.
    local wantW = 340
    if mode == "compare" then
        local count = 0
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
    elseif mode == "plan" then BuildPlan(out)
    else BuildByPlayer(out) end

    -- While teammates' lists are still arriving the window keeps showing what it had, with a note on top.
    if IsSyncing() then
        table.insert(out, 1, { "|cffffd200Syncing with teammates...|r", 0, 0 })
    end

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
    local follows = {}   -- name areas that can be Shift-clicked to follow that player
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
            b.share = e.shareOnClick
            b.guide = guide
            b.guideWho = guide and e.guideWho or nil   -- set when someone else needs that quest first
            b.guideTitle =guide and (e[1]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r.*$", "")) or nil
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", e[2], -y)
            b:SetSize(e.titleW or (W - e[2]), h)
            b:Show()
        end
        if e.follow then follows[#follows + 1] = { key = e.follow, x = e[2], y = y, w = fs:GetStringWidth() + 6, h = h } end
        for _, c in ipairs(e.cells or {}) do
            if c.follow then follows[#follows + 1] = { key = c.follow, x = c.x, y = y, w = c.w, h = h } end
        end
        y = y + h
    end
    ApplyFollowButtons(follows)
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
        for _, q in pairs(m.ghost and {} or Visible(m)) do   -- (offline teammates' old progress isn't shown on tooltips)
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

-- Tooltip names/units can be "secret" values (e.g. world-cursor tooltips in
-- combat): tainted code may not pass them to UnitIsPlayer or string functions.
local IsSecret = issecretvalue or function() return false end

local function OnUnitTooltip(tt)
    if tt ~= GameTooltip then return end
    local ok, name, unit = pcall(tt.GetUnit, tt)
    if not ok or not unit or IsSecret(unit) or IsSecret(name) then return end
    local okP, isPlayer = pcall(UnitIsPlayer, unit)
    if not okP or IsSecret(isPlayer) or isPlayer then return end
    AddProgress(tt, name)
end

local function OnItemTooltip(tt)
    if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
    local ok, name = pcall(tt.GetItem, tt)
    if ok and not IsSecret(name) then AddProgress(tt, name) end
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
    onClick = function()
        ToggleWindow()
        -- the quest window opened: close the /p13 menu this button is in
        if win and win:IsShown() and ns.optionsFrame then ns.optionsFrame:Hide() end
    end,
    tooltip = "Sends your quests and their progress to group members who also have P13Tweaks, and shows theirs.\n\nView (or /p13 quests) opens the list of your teammates' quests. Teammates without P13Tweaks can't show up: the game doesn't let addons read someone else's quest log.",
    default = true,
    onChange = function(on)
        if on then
            wipe(roster); wipe(lastSent); wipe(sentDone)
            OnRoster()   -- says hello and sends my list if I'm in a group
        else
            Send("X")
            wipe(lastSent)
            wipe(incoming)
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
    key = "questShareRemember",
    type = "toggle",
    label = "Remember teammates' quests when they're offline",
    tooltip = "Saves each teammate's quests as they play. When a teammate who is still in your group goes offline, their last known quests still show in the teammates' quests window (tagged \"last known 2 h ago\"). People who have left the group are not shown. Kept for 30 days. Turning this off deletes the saved copies.",
    default = true,
    onChange = function(on)
        if on then
            SyncGhosts()
        else
            P13TweaksDB.lastKnown = nil
            SyncGhosts()   -- removes the ghosts (nothing is remembered now)
        end
        RefreshWindow()
    end,
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

-- (The world-map markers for teammates' quests, MapQuestHints.lua, were removed in 0.31.10: nothing about what
-- other people have or did is drawn on the map any more.)

ns:RegisterCommand("sync", "ask your group to resend their quests right now (syncing is automatic; this is a fallback)", function()
    if not Sharing() then ns:Print("Quest sharing is off - turn it on in /p13."); return end
    if not Channel() then ns:Print("You're not in a group."); return end
    AskAgain()
end)

ns:RegisterCommand("questsdebug","show how the addon sees your name and your teammates' names (for duplicate-name problems)", function()
    ns:Print(("UnitName: \"%s\" | GetUnitName: \"%s\" | realm: \"%s\" / \"%s\""):format(
        tostring(UnitName("player")), tostring(GetUnitName and GetUnitName("player", true)),
        tostring(GetRealmName and GetRealmName()), tostring(GetNormalizedRealmName and GetNormalizedRealmName())))
    local any = false
    for name, m in pairs(members) do
        any = true
        ns:Print(("teammate \"%s\"%s%s"):format(name, IsMe(name) and " (this is ME - should have been ignored)" or "",
            m.demo and " (pretend)" or ""))
    end
    if not any then ns:Print("No teammates stored.") end
    local kinds = {}
    for k, n in pairs(stats.msg) do kinds[#kinds + 1] = k .. "=" .. n end
    table.sort(kinds)
    ns:Print(("how my name looks to others: \"%s\" | hellos sent %d | full lists sent %d | lists applied %d | newcomers seen %d | messages received: %s"):format(
        tostring(myNetName), stats.hello, stats.full, stats.apply, stats.newcomer, #kinds > 0 and table.concat(kinds, " ") or "none"))
end)

ns:RegisterCommand("version","show your P13Tweaks version and your teammates'", function()
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
    -- Bob is level 1, so quests with a level requirement land under "Can't be shared yet" in the sync plan.
    return { quests = quests, done = done, demo = true, version = which == 1 and ns.version or "0.3.9",
        level = which == 1 and UnitLevel("player") or 1, race = select(3, UnitRace("player")),
        class = select(3, UnitClass("player")), numQuests = 5 }
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
-- Events that mean one of my quests changed (not every one exists on every game version, so a missing one is skipped).
local MINE_EVENTS = { QUEST_LOG_UPDATE = true, UNIT_QUEST_LOG_CHANGED = true, QUEST_ACCEPTED = true,
    QUEST_REMOVED = true, QUEST_TURNED_IN = true, QUEST_WATCH_UPDATE = true }
for name in pairs(MINE_EVENTS) do pcall(frame.RegisterEvent, frame, name) end
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:SetScript("OnEvent", function(self, event, a1, a2, a3, a4)
    if event == "PLAYER_LOGIN" then
        pcall(HookTooltips)
        pcall(PruneKnown)
        pcall(SyncGhosts)   -- teammates who aren't here: show what we last knew
        C_Timer.NewTicker(30, function() SendFingerprint() end)   -- heartbeat: teammates compare it with their copy of my quests
    elseif event == "PLAYER_LEVEL_UP" then
        Later("profile", 3, SendProfile)
    elseif event == "QUEST_DETAIL" then
        -- A group member shared a quest: the "npc" giving it is a player in my group.
        if ns:Get("questShareAuto") and UnitIsPlayer("npc") and (UnitInParty("npc") or UnitInRaid("npc")) then
            pcall(AcceptQuest)
        end
    elseif event == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 and a4 then OnMessage(a2, a4) end
    elseif MINE_EVENTS[event] then
        -- A quest changed (progress, accepted, turned in, abandoned): re-read my log shortly and send only what changed.
        -- 0.25 s is short enough that teammates see it at about the same moment; several events in a row become one look.
        Later("mine", 0.25, UpdateMine)
    else
        -- PLAYER_ENTERING_WORLD (login, /reload) and GROUP_ROSTER_UPDATE
        Later("roster", 1, OnRoster)
    end
end)

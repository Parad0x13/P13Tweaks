-- P13Tweaks feature: a key that targets only mobs your quests still need: mobs to kill, and
-- (when QuestieDB is installed) mobs that drop items your quests ask you to collect.
-- Addons can't choose targets themselves, so this is a secure macro button the game lets
-- you bind to a key (Esc > Key Bindings > P13Tweaks). The macro can't be rebuilt in combat;
-- quest changes made mid-fight apply when combat ends.
local ADDON_NAME, ns = ...

local BUTTON_NAME = "P13TweaksPriorityTarget"
local MAX_MACRO = 1023

_G["BINDING_NAME_CLICK " .. BUTTON_NAME .. ":LeftButton"] = "Target quest mob"

local button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
button:SetAttribute("type", "macro")
button:RegisterForClicks("AnyUp", "AnyDown")

local pendingAfterCombat = false

---------------------------------------------------------------------------
-- Reading the quest log
---------------------------------------------------------------------------

-- Turn a game format string like "%s slain: %d/%d" into a pattern capturing the name.
local function NamePattern(fmt)
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")  -- escape everything ("%s" -> "%%s")
    p = p:gsub("%%%%s", "(.+)")
    p = p:gsub("%%%%d", "%%d+")
    return "^" .. p .. "$"
end
local KILL_PATTERN = NamePattern(QUEST_MONSTERS_KILLED or "%s slain: %d/%d")
local ITEM_PATTERN = NamePattern(QUEST_ITEMS_NEEDED or "%s: %d/%d")

-- Pull the mob/item name out of objective text like "Defias Bandit slain: 3/12".
local function NameFromObjective(text, pattern)
    if not text then return end
    local name = text:match(pattern)
    if not name then  -- fallback: strip a trailing ": 3/12" and the word "slain"/"killed"
        name = text:gsub("[:%s]*%d+%s*/%s*%d+%s*$", ""):gsub("%s+[Ss]lain$", ""):gsub("%s+[Kk]illed$", "")
    end
    name = strtrim(name or "")
    if name ~= "" then return name end
end

local function NumQuestEntries()
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then return (C_QuestLog.GetNumQuestLogEntries()) end
    return (GetNumQuestLogEntries())
end

-- Returns isHeader, questID, isCollapsed, title for a quest log line.
local function QuestEntry(i)
    if C_QuestLog and C_QuestLog.GetInfo then
        local info = C_QuestLog.GetInfo(i)
        if info then return info.isHeader, info.questID, info.isCollapsed, info.title end
        return true
    end
    local title, _, _, isHeader, isCollapsed, _, _, questID = GetQuestLogTitle(i)
    return isHeader, questID, isCollapsed, title
end

-- Quests under a collapsed header are invisible to addons. So: expand every collapsed header,
-- run fn, then collapse the same headers again. It all happens within one frame, so you never
-- see it. Walking bottom-to-top keeps the line numbers above us from shifting.
local ignoreLogUpdatesUntil = 0
local function WithAllQuestsVisible(fn)
    if not (ExpandQuestHeader and CollapseQuestHeader) then return fn() end

    local reopened = {}
    for i = NumQuestEntries() or 0, 1, -1 do
        local isHeader, _, isCollapsed, title = QuestEntry(i)
        if isHeader and isCollapsed and title then
            reopened[title] = true
            ExpandQuestHeader(i)
        end
    end
    if not next(reopened) then return fn() end

    -- Expanding can move the quest log's selection; remember it so we can put it back.
    local selectedID = C_QuestLog and C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
    local selectedIndex = (not selectedID) and GetQuestLogSelection and GetQuestLogSelection()

    local ok, result = pcall(fn)

    for i = NumQuestEntries() or 0, 1, -1 do
        local isHeader, _, isCollapsed, title = QuestEntry(i)
        if isHeader and not isCollapsed and title and reopened[title] then CollapseQuestHeader(i) end
    end
    if selectedID and C_QuestLog.SetSelectedQuest then
        C_QuestLog.SetSelectedQuest(selectedID)
    elseif selectedIndex and selectedIndex > 0 and SelectQuestLogEntry then
        SelectQuestLogEntry(selectedIndex)
    end

    -- Our own expand/collapse fires QUEST_LOG_UPDATE; don't let that trigger another scan.
    ignoreLogUpdatesUntil = GetTime() + 1
    if not ok then error(result, 0) end
    return result
end

-- Unfinished objectives of one quest: { {type=, text=}, ... }
local function Objectives(i, questID)
    local list = {}
    local newAPI = questID and C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
    if type(newAPI) == "table" and #newAPI > 0 then
        for j, obj in ipairs(newAPI) do
            local text, objType, finished = obj.text, obj.type, obj.finished
            -- The game sometimes hands back blank text until it has loaded the quest; try the older API.
            if (not text or text == "") and GetQuestLogLeaderBoard then
                local t2, ty2, f2 = GetQuestLogLeaderBoard(j, i)
                if t2 and t2 ~= "" then text, objType, finished = t2, ty2 or objType, f2 end
            end
            if not finished then table.insert(list, { type = objType, text = text }) end
        end
    elseif GetNumQuestLeaderBoards then
        for j = 1, GetNumQuestLeaderBoards(i) or 0 do
            local text, objType, finished = GetQuestLogLeaderBoard(j, i)
            if not finished then table.insert(list, { type = objType, text = text }) end
        end
    end
    return list
end

---------------------------------------------------------------------------
-- QuestieDB (optional): which mobs drop quest items / give kill credit
---------------------------------------------------------------------------

local function DB(entity, id, field)
    local lib = _G.LibQuestieDB
    if not (lib and lib[entity] and lib[entity].Get and id) then return end
    local ok, value = pcall(lib[entity].Get, id, field)
    if ok then return value end
end

local function NpcName(npcID) return DB("Npc", npcID, "name") end

-- Adds mobs for one quest's unfinished "collect" and kill-credit objectives.
local function AddQuestieMobs(questID, wantItems, wantKills, add)
    local objectives = DB("Quest", questID, "objectives")
    if type(objectives) ~= "table" then return end

    -- objectives[3] = items to collect: { {itemID, ...}, ... }
    for _, entry in ipairs(objectives[3] or {}) do
        local itemID = entry[1]
        local itemName = DB("Item", itemID, "name")
        if itemName and wantItems[itemName:lower()] then
            for _, npcID in ipairs(DB("Item", itemID, "npcDrops") or {}) do add(NpcName(npcID)) end
        end
    end

    -- objectives[5] = kill credit: { { {npcIDs}, creditNpcID, text }, ... }
    -- e.g. "Defias Traitor slain" might be credited by several differently-named mobs.
    for _, entry in ipairs(objectives[5] or {}) do
        local creditName = entry[3] or NpcName(entry[2])
        if creditName and wantKills[creditName:lower()] then
            for _, npcID in ipairs(entry[1] or {}) do add(NpcName(npcID)) end
        end
    end
end

-- Every mob your quests still need, kill objectives first, without duplicates.
local function ScanNames()
    local names, seen = {}, {}
    local function add(name)
        if name and name ~= "" and not seen[name:lower()] then
            seen[name:lower()] = true
            table.insert(names, name)
        end
    end

    local questieWork = {}
    for i = 1, NumQuestEntries() or 0 do
        local isHeader, questID = QuestEntry(i)
        if not isHeader then
            local wantItems, wantKills = {}, {}
            for _, obj in ipairs(Objectives(i, questID)) do
                if obj.type == "monster" then
                    local mob = NameFromObjective(obj.text, KILL_PATTERN)
                    if mob then add(mob); wantKills[mob:lower()] = true end
                elseif obj.type == "item" then
                    local item = NameFromObjective(obj.text, ITEM_PATTERN)
                    if item then wantItems[item:lower()] = true end
                end
            end
            if questID and (next(wantItems) or next(wantKills)) then
                table.insert(questieWork, { questID, wantItems, wantKills })
            end
        end
    end

    -- Drop sources go after all direct kill targets.
    -- Guarded: a surprise in QuestieDB's data must never break the kill-target list.
    ns.questTargetError = nil
    for _, w in ipairs(questieWork) do
        local ok, err = pcall(AddQuestieMobs, w[1], w[2], w[3], add)
        if not ok then ns.questTargetError = "quest " .. tostring(w[1]) .. ": " .. tostring(err) end
    end
    return names
end

local function AllNames() return WithAllQuestsVisible(ScanNames) end

local function Build()
    if InCombatLockdown() then pendingAfterCombat = true; return end
    local lines, length, dropped = {}, 0, false
    if ns:Get("priorityTarget") then
        local ok, names = pcall(AllNames)
        if not ok then
            ns.questTargetError = tostring(names)
            names = {}
        end
        for _, name in ipairs(names) do            -- highest priority first
            local line = "/target " .. name
            if length + #line + 1 > MAX_MACRO then dropped = true; break end
            table.insert(lines, 1, line)          -- in a macro the LAST match wins, so prepend
            length = length + #line + 1
        end
    end
    if dropped and not ns.warnedLongTargets then
        ns.warnedLongTargets = true
        ns:Print("Lots of quest mobs right now; only the first " .. #lines .. " fit in the target key.")
    end
    button:SetAttribute("macrotext", table.concat(lines, "\n"))
end

ns:RegisterOption({
    key = "priorityTarget",
    type = "toggle",
    label = "Quest target key",
    tooltip = "A key that targets only mobs your unfinished quests still need: mobs to kill, plus mobs that drop items you need to collect (uses QuestieDB if installed). Set the key in Esc > Key Bindings > P13Tweaks (\"Target quest mob\"). Updates as your quests change, but only out of combat. /p13 targets lists them in chat.",
    default = true,
    onChange = function() Build(); ns:RefreshOptions() end,
})

ns:RegisterOption({
    key = "priorityTargetQuestInfo",
    type = "info",
    label = "From quests",
    getText = function()
        if not ns:Get("priorityTarget") then return "Quest mobs: (off)" end
        local mobs = AllNames()
        local text
        if #mobs == 0 then
            text = "Quest mobs: (none needed right now)"
        else
            text = "Quest mobs (" .. #mobs .. "): " .. table.concat(mobs, ", ")
        end
        if ns.questTargetError then
            text = "|cffff5555Drop lookup error, " .. ns.questTargetError .. "|r\n" .. text
        end
        return text
    end,
})

-- Diagnostic: dump what the quest log reports, and what we make of it.
local function QuestDebug(filter)
    filter = (filter or ""):lower()
    local lib = _G.LibQuestieDB
    ns:Print("QuestieDB " .. (lib and "found" or "NOT found") .. ". Quest log lines (collapsed sections opened): " .. tostring(NumQuestEntries()))
    for i = 1, NumQuestEntries() or 0 do
        local isHeader, questID, _, title = QuestEntry(i)
        if not isHeader and (filter == "" or tostring(title):lower():find(filter, 1, true)) then
            ns:Print("|cffffff00" .. tostring(title) .. "|r (id " .. tostring(questID) .. ")")
            local objectives = Objectives(i, questID)   -- exactly what the target key uses
            if #objectives == 0 then ns:Print("   (no unfinished objectives)") end
            for _, obj in ipairs(objectives) do
                local parsed = obj.type == "item" and NameFromObjective(obj.text, ITEM_PATTERN)
                            or NameFromObjective(obj.text, KILL_PATTERN)
                ns:Print(("   [%s] \"%s\" -> %s"):format(tostring(obj.type), tostring(obj.text), tostring(parsed)))
                if obj.type == "item" and parsed and lib then
                    local objectives = DB("Quest", questID, "objectives")
                    local found = false
                    for _, entry in ipairs(type(objectives) == "table" and objectives[3] or {}) do
                        local itemName = DB("Item", entry[1], "name")
                        if itemName and itemName:lower() == parsed:lower() then
                            found = true
                            local mobs = {}
                            for _, npcID in ipairs(DB("Item", entry[1], "npcDrops") or {}) do
                                table.insert(mobs, tostring(NpcName(npcID)))
                            end
                            ns:Print("      dropped by: " .. (#mobs > 0 and table.concat(mobs, ", ") or "(QuestieDB lists no mobs)"))
                        end
                    end
                    if not found then ns:Print("      |cffff5555QuestieDB has no item called that for this quest|r") end
                end
            end
        end
    end
end

ns:RegisterCommand("questdebug", "print every quest objective the quest target key sees", function(filter)
    WithAllQuestsVisible(function() QuestDebug(filter) end)
end)

ns:RegisterCommand("targets", "list the mobs the quest target key looks for", function()
    local names = AllNames()
    if #names == 0 then
        ns:Print("No quest kill objectives right now.")
    else
        ns:Print("Quest targets (" .. #names .. "): " .. table.concat(names, ", "))
    end
    if ns.questTargetError then ns:Print("|cffff5555Drop lookup error, " .. ns.questTargetError .. "|r") end
end)

-- QUEST_LOG_UPDATE fires in bursts, so wait a moment and rebuild once.
local rebuildQueued = false
local function QueueBuild()
    if rebuildQueued then return end
    rebuildQueued = true
    C_Timer.After(0.5, function()
        rebuildQueued = false
        Build()              -- waits until after combat if needed
        ns:RefreshOptions()  -- the "From quests" line updates right away
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:SetScript("OnEvent", function(self, event)
    if event == "QUEST_LOG_UPDATE" then
        if ns:Get("priorityTarget") and GetTime() >= ignoreLogUpdatesUntil then QueueBuild() end
    elseif event == "PLAYER_LOGIN" or pendingAfterCombat then
        -- tidy up settings from the removed typed-names box
        P13TweaksDB.priorityTargetNames, P13TweaksDB.priorityTargetQuests = nil, nil
        pendingAfterCombat = false
        Build()
        if event == "PLAYER_LOGIN" then
            -- Quest data can arrive a few seconds after login; look again once it has.
            C_Timer.After(5, QueueBuild)
            C_Timer.After(15, QueueBuild)
        end
    end
end)

-- P13Tweaks feature: an on-screen arrow to the nearest enemy you still need for a quest.
-- For every quest in your log, each unfinished objective is matched (by name) to QuestieDB's
-- objectives: creatures to kill, kill-credit groups, and items - for items, the creatures
-- that drop them. The arrow points at the nearest SPAWN POINT of any of those creatures
-- (addons can't see where mobs actually are), with the name, quest and distance under it.
-- Needs QuestieDB. Drag the arrow to move it.
--
-- Directions: world X = north, Y = west (as UnitPosition gives them). GetPlayerFacing() is 0
-- facing north and grows turning left; atan2(dY, dX) uses the same convention, so the arrow's
-- rotation is simply bearing - facing (SetRotation turns the up-pointing arrow anticlockwise).
local ADDON_NAME, ns = ...

local ARROW = "Interface\\AddOns\\P13Tweaks\\Media\\Arrow.tga"
local RING  = "Interface\\AddOns\\P13Tweaks\\Media\\Ring.tga"
-- Fake 3D: the arrow lies on the ground in front of you. Its box is half as tall as wide, and
-- SetRotation turns the picture inside that box, so the arrow is drawn foreshortened like a
-- flat shape seen at an angle: ahead = it points up the screen, behind = it points down at you.
local SIZE, TILT = 64, 0.5   -- width, and height as a share of it
local SHRINK = 0.3           -- up to this much smaller when the target is behind you
local SCAN_DELAY = 1.0       -- seconds after a quest log change before re-reading it
local NEAREST_EVERY = 0.5    -- seconds between nearest-spawn searches
local HERE_YARDS = 15        -- this close to the spawn point: "around here"

-- (all file-level locals up here, before any function uses them)
local frame, arrow, label, shadow, ring
local targets = {}           -- { npcId, npcName, quest, objective }
local spawnCache = {}        -- npcId -> { { inst, X, Y }, ... }
local nearest                -- { t = target, X, Y, dist }
local scanPending = false
local Scan

local function On() return ns:Get("questMobArrow") end
local function Lib()
    local lib = _G.LibQuestieDB
    if lib and lib.Quest and lib.Quest.Get and lib.Npc and lib.Npc.Get and lib.Item and lib.Item.Get then return lib end
end

local function Get(db, id, field)
    local ok, v = pcall(db.Get, id, field)
    if ok then return v end
end

---------------------------------------------------------------------------
-- Your quests: which creatures still count for something
---------------------------------------------------------------------------

local function NumEntries()
    if GetNumQuestLogEntries then return (GetNumQuestLogEntries()) or 0 end
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then return (C_QuestLog.GetNumQuestLogEntries()) or 0 end
    return 0
end

-- title, isHeader, questID
local function Entry(i)
    if GetQuestLogTitle then
        local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
        return title, isHeader, questID
    elseif C_QuestLog and C_QuestLog.GetInfo then
        local info = C_QuestLog.GetInfo(i)
        if info then return info.title, info.isHeader, info.questID end
    end
end

-- Unfinished objective texts of a quest, e.g. "Galestrider slain: 3/10".
local function OpenObjectives(i, questID)
    local list = {}
    if C_QuestLog and C_QuestLog.GetQuestObjectives and questID then
        local ok, objs = pcall(C_QuestLog.GetQuestObjectives, questID)
        if ok and type(objs) == "table" and #objs > 0 then
            for _, o in ipairs(objs) do
                if o.text and o.text ~= "" and not o.finished then table.insert(list, o.text) end
            end
            return list
        end
    end
    if GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
        for j = 1, (GetNumQuestLeaderBoards(i) or 0) do
            local text, _, finished = GetQuestLogLeaderBoard(j, i)
            if text and text ~= "" and not finished then table.insert(list, text) end
        end
    end
    return list
end

local function Has(text, name)
    return type(name) == "string" and name ~= "" and text:lower():find(name:lower(), 1, true) ~= nil
end

Scan = function()
    scanPending = false
    wipe(targets)
    nearest = nil
    local lib = Lib()
    if not lib then return end
    local seen = {}
    local function Add(npcId, quest, objective)
        local key = npcId .. ":" .. quest
        if seen[key] then return end
        seen[key] = true
        table.insert(targets, { npcId = npcId, npcName = Get(lib.Npc, npcId, "name") or "?", quest = quest, objective = objective })
    end

    for i = 1, NumEntries() do
        local title, isHeader, questID = Entry(i)
        if title and not isHeader and questID and questID > 0 then
            local open = OpenObjectives(i, questID)
            local db = #open > 0 and Get(lib.Quest, questID, "objectives")
            if type(db) == "table" then
                for _, text in ipairs(open) do
                    -- creatures to kill
                    for _, o in ipairs(db[1] or {}) do
                        local name = o[2] or Get(lib.Npc, o[1], "name")
                        if Has(text, name) or Has(text, Get(lib.Npc, o[1], "name")) then Add(o[1], title, text) end
                    end
                    -- kill credit: any of a group of creatures
                    for _, o in ipairs(db[5] or {}) do
                        if Has(text, o[3]) or Has(text, Get(lib.Npc, o[2], "name")) then
                            for _, id in ipairs(o[1] or {}) do Add(id, title, text) end
                            if o[2] then Add(o[2], title, text) end
                        end
                    end
                    -- items: the creatures that drop them
                    for _, o in ipairs(db[3] or {}) do
                        local name = o[2] or Get(lib.Item, o[1], "name")
                        if Has(text, name) or Has(text, Get(lib.Item, o[1], "name")) then
                            for _, id in ipairs(Get(lib.Item, o[1], "npcDrops") or {}) do Add(id, title, text) end
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Where those creatures spawn, and which spot is nearest
---------------------------------------------------------------------------

local function Spawns(npcId)
    if spawnCache[npcId] then return spawnCache[npcId] end
    local list = {}
    local lib = Lib()
    local spawns = lib and Get(lib.Npc, npcId, "spawns")
    local areaMap = ns.LoadAreaMap and ns.LoadAreaMap() or {}
    if type(spawns) == "table" and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        for area, points in pairs(spawns) do
            local uiMap = areaMap[area]
            if uiMap and uiMap ~= 0 then
                for _, pt in ipairs(points) do
                    local x, y = pt[1], pt[2]
                    if x and y and x >= 0 and y >= 0 then
                        local inst, w = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(x / 100, y / 100))
                        if inst and w then
                            local X, Y = w:GetXY()
                            table.insert(list, { inst, X, Y })
                        end
                    end
                end
            end
        end
    end
    spawnCache[npcId] = list
    return list
end

local function PlayerWorld()
    local X, Y, _, inst = UnitPosition("player")
    if X == nil or (issecretvalue and (issecretvalue(X) or issecretvalue(Y))) then return end
    return X, Y, inst
end

local function FindNearest()
    local old = nearest
    nearest = nil
    local X, Y, inst = PlayerWorld()
    if not X then return end
    local best, oldStill
    for _, t in ipairs(targets) do
        for _, s in ipairs(Spawns(t.npcId)) do
            if s[1] == inst then
                local d = (s[2] - X) ^ 2 + (s[3] - Y) ^ 2
                if not best or d < best then
                    best = d
                    nearest = { t = t, X = s[2], Y = s[3] }
                end
                if old and old.t == t and s[2] == old.X and s[3] == old.Y then oldStill = math.sqrt(d) end
            end
        end
    end
    if not nearest then return end
    nearest.dist = math.sqrt(best)
    -- Don't flip between two spots that are about as far: keep the old one unless the new one
    -- is clearly closer (15 % or 10 yards).
    if oldStill and nearest.dist > math.min(oldStill * 0.85, oldStill - 10) then
        old.dist = oldStill
        nearest = old
    end
end

---------------------------------------------------------------------------
-- The arrow
---------------------------------------------------------------------------

-- The direction the arrow is drawn at, eased toward the real one each frame (smooth turning).
local shownRel
local EASE = 18   -- higher = snappier

local function Wrap(a) return ((a + math.pi) % (2 * math.pi)) - math.pi end

local function UpdateArrow(elapsed)
    if not (On() and nearest) then frame:Hide(); return end
    local X, Y = PlayerWorld()
    if not X then frame:Hide(); return end
    local dX, dY = nearest.X - X, nearest.Y - Y
    local dist = math.sqrt(dX * dX + dY * dY)
    local facing = GetPlayerFacing and GetPlayerFacing()
    local where = ""
    if dist <= HERE_YARDS then
        arrow:Hide(); shadow:Hide(); ring:Hide()
    elseif facing and not (issecretvalue and issecretvalue(facing)) then
        -- rel: 0 = straight ahead, + = to your left, - = to your right (-pi..pi)
        local target = Wrap(math.atan2(dY, dX) - facing)
        if not shownRel or not elapsed then
            shownRel = target
        else
            shownRel = Wrap(shownRel + Wrap(target - shownRel) * math.min(1, elapsed * EASE))
        end
        local rel = shownRel
        local k = math.abs(rel) / math.pi                 -- 0 ahead .. 1 behind
        local s = 1 - SHRINK * k                          -- a bit smaller when behind (further away)
        for _, tex in ipairs({ arrow, shadow, ring }) do
            tex:SetSize(SIZE * s, SIZE * TILT * s)
        end
        arrow:SetRotation(rel)
        shadow:SetRotation(rel)
        -- green ahead, yellow to the side, red behind
        arrow:SetVertexColor(math.min(1, k * 2), math.min(1, 2 - k * 2), 0.2)
        arrow:Show(); shadow:Show(); ring:Show()
        local a = math.abs(rel)
        local side = rel > 0 and "left" or "right"
        if a < 0.35 then where = "ahead"
        elseif a < 1.2 then where = "ahead, " .. side
        elseif a < 1.95 then where = "to your " .. side
        elseif a < 2.8 then where = "|cffff6060behind you|r, " .. side
        else where = "|cffff6060behind you|r" end
    else
        arrow:Hide(); shadow:Hide(); ring:Hide()   -- the game hides your facing here (some instances)
    end
    local t = nearest.t
    label:SetText(("%s\n|cffaaaaaa%s|r\n%s"):format(t.npcName, t.quest,
        dist <= HERE_YARDS and "|cff55ff55around here - look about|r"
        or ("%d yd%s"):format(dist, where ~= "" and ("  -  " .. where) or "")))
    frame:Show()
end

---------------------------------------------------------------------------
-- Options, command, setup
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "questMobArrow",
    type = "toggle",
    label = "Arrow to the nearest quest enemy",
    tooltip = "Shows an arrow on screen pointing at the nearest place where a creature you still need for a quest spawns (kill objectives, and creatures that drop quest items), with its name, the quest and the distance. It points at spawn points - mobs wander, so look around when you get there. Drag the arrow to move it.\n\nNeeds QuestieDB enabled on this character.",
    default = true,
    onChange = function() if frame then UpdateArrow() end end,
})

ns:RegisterCommand("mobarrow", "list what the quest enemy arrow is looking for", function()
    Scan()
    FindNearest()
    if not Lib() then ns:Print("Quest enemy arrow: QuestieDB isn't loaded on this character."); return end
    if #targets == 0 then ns:Print("Quest enemy arrow: no unfinished kill / drop objectives found in your quest log."); return end
    local byQuest = {}
    for _, t in ipairs(targets) do
        byQuest[t.quest] = byQuest[t.quest] or {}
        table.insert(byQuest[t.quest], t.npcName)
    end
    for quest, names in pairs(byQuest) do ns:Print(("  %s: %s"):format(quest, table.concat(names, ", "))) end
    if nearest then
        ns:Print(("Nearest: %s (%s), %d yd."):format(nearest.t.npcName, nearest.t.quest, nearest.dist))
    else
        ns:Print("None of them spawn on this continent (or your position is unknown here).")
    end
end)

frame = CreateFrame("Frame", "P13TweaksQuestMobArrow", UIParent)
frame:SetSize(SIZE, SIZE * TILT)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint(1)
    P13TweaksDB.questMobArrowPos = { point, relPoint, x, y }
end)
frame:Hide()
-- a faint ring on the "ground", a soft shadow, then the arrow itself
ring = frame:CreateTexture(nil, "BACKGROUND")
ring:SetPoint("CENTER")
ring:SetSize(SIZE, SIZE * TILT)
ring:SetTexture(RING)
ring:SetVertexColor(1, 1, 1, 0.35)
shadow = frame:CreateTexture(nil, "BORDER")
shadow:SetPoint("CENTER", 2, -4)
shadow:SetSize(SIZE, SIZE * TILT)
shadow:SetTexture(ARROW)
shadow:SetVertexColor(0, 0, 0, 0.5)
arrow = frame:CreateTexture(nil, "ARTWORK")
arrow:SetPoint("CENTER")
arrow:SetSize(SIZE, SIZE * TILT)
arrow:SetTexture(ARROW)
label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("TOP", frame, "BOTTOM", 0, -2)
label:SetJustifyH("CENTER")
label:SetShadowOffset(1, -1)

-- Every frame while shown: smooth turning.
local sinceNearest = 0
frame:SetScript("OnUpdate", function(_, elapsed) UpdateArrow(elapsed) end)

-- The search runs even while the arrow is hidden (it shows up as soon as there's something).
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
    sinceNearest = sinceNearest + elapsed
    if sinceNearest < NEAREST_EVERY then return end
    sinceNearest = 0
    if not On() then frame:Hide(); return end
    FindNearest()
    UpdateArrow(0)   -- (0: shows/hides it without disturbing the smooth turning)
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local p = P13TweaksDB.questMobArrowPos
        frame:ClearAllPoints()
        if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        else frame:SetPoint("TOP", UIParent, "TOP", 0, -120) end
    end
    -- quest log changes come in bursts: read it once things settle
    if not scanPending then
        scanPending = true
        C_Timer.After(SCAN_DELAY, function() pcall(Scan) end)
    end
end)

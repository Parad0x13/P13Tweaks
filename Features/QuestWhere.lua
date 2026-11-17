-- P13Tweaks feature: "How do I get this quest?"
-- Click a quest in the teammates' quests window that you don't have, and a small panel tells you
-- what stands between you and it: level / race / class limits, quests you must finish first (a tree
-- with done / in-your-log / not-done marks), the next quest to start, and who gives it and where.
-- A button puts a map waypoint on the quest giver. Also: /p13 questhow <questID>.
--
-- Everything comes from QuestieDB (quest records: name, startedBy, requiredLevel, preQuestGroup,
-- preQuestSingle, exclusiveTo, parentQuest...). Without QuestieDB the panel says so.
-- Your own progress comes from QuestShare.lua (ns.QuestCompleted, ns.HasQuest).
local ADDON_NAME, ns = ...

local PANEL_W = 400
local MAX_DEPTH = 6

local function Lib()
    local lib = _G.LibQuestieDB
    if lib and lib.Quest and lib.Quest.Get and lib.Npc and lib.Npc.Get then return lib end
end

local function Get(db, id, field)
    if not (db and db.Get) then return end
    local ok, v = pcall(db.Get, id, field)
    if ok then return v end
end

local function Done(id) return ns.QuestCompleted and ns.QuestCompleted(id) or false end
local function InLog(id) return ns.HasQuest and ns.HasQuest(id) or false end

-- QuestieDB lists of quest ids -> a plain array of numbers
local function IdList(v)
    local t = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do if type(x) == "number" and x > 0 then t[#t + 1] = x end end
    elseif type(v) == "number" and v > 0 then
        t[1] = v
    end
    return t
end

local function QName(lib, id) return Get(lib.Quest, id, "name") or ("quest " .. id) end

local function Status(id)
    if Done(id) then return "|cff40ff40done|r" end
    if InLog(id) then return "|cff8fa8ffin your log|r" end
    return "|cffffa040not done|r"
end

---------------------------------------------------------------------------
-- What blocks you from taking a quest
---------------------------------------------------------------------------

-- Who the checks are for: me (the default), or a teammate described by what they told us:
-- { name, level, raceId, classId, done = fn(id), has = fn(id), checkPrereqs = true }.
local function Me()
    local _, _, raceId = UnitRace("player")
    local _, _, classId = UnitClass("player")
    return { level = UnitLevel("player"), raceId = raceId, classId = classId, done = Done, has = InLog }
end

local function Blockers(lib, id, who)
    who = who or Me()
    local out = {}
    local refs = {}   -- quest ids mentioned above that the player could go and find (second return value)
    local are = who.name and (who.name .. " is") or "you're"
    local they = who.name or "you"
    local level = who.level
    local need = Get(lib.Quest, id, "requiredLevel")
    if level and type(need) == "number" and need > level then
        out[#out + 1] = ("needs level %d (%s %d)"):format(need, are, level)
    end
    local maxLevel = Get(lib.Quest, id, "requiredMaxLevel")
    if level and type(maxLevel) == "number" and maxLevel > 0 and level > maxLevel then
        out[#out + 1] = ("only for level %d or lower (%s %d)"):format(maxLevel, are, level)
    end
    local races = Get(lib.Quest, id, "requiredRaces")
    local raceId = who.raceId
    if type(races) == "number" and races > 0 and raceId and raceId <= 31
        and bit.band(races, bit.lshift(1, raceId - 1)) == 0 then
        out[#out + 1] = "not available to " .. (who.name and "their" or "your") .. " race"
    end
    local classes = Get(lib.Quest, id, "requiredClasses")
    local classId = who.classId
    if type(classes) == "number" and classes > 0 and classId and classId <= 31
        and bit.band(classes, bit.lshift(1, classId - 1)) == 0 then
        out[#out + 1] = "not available to " .. (who.name and "their" or "your") .. " class"
    end
    for _, other in ipairs(IdList(Get(lib.Quest, id, "exclusiveTo"))) do
        local d, h = who.done(other), who.has(other)
        if d or h then
            out[#out + 1] = ("%s can't take it because of \"%s\" (%s)"):format(they, QName(lib, other), d and "done" or "in their log")
        end
    end
    local parent = Get(lib.Quest, id, "parentQuest")
    if type(parent) == "number" and parent > 0 and not who.has(parent) and not who.done(parent) then
        out[#out + 1] = ("it starts from inside \"%s\" - that quest comes first"):format(QName(lib, parent))
        refs[#refs + 1] = parent
    end
    if who.checkPrereqs then
        for _, pid in ipairs(IdList(Get(lib.Quest, id, "preQuestGroup"))) do
            if not who.done(pid) then
                out[#out + 1] = ("needs \"%s\" finished first"):format(QName(lib, pid))
                refs[#refs + 1] = pid
            end
        end
        local single = IdList(Get(lib.Quest, id, "preQuestSingle"))
        if #single > 0 then
            local any = false
            for _, pid in ipairs(single) do if who.done(pid) then any = true end end
            if not any then
                local names = {}
                for i = 1, math.min(3, #single) do
                    names[i] = "\"" .. QName(lib, single[i]) .. "\""
                    refs[#refs + 1] = single[i]
                end
                out[#out + 1] = "needs one of these finished first: " .. table.concat(names, ", ")
            end
        end
    end
    local rep = Get(lib.Quest, id, "requiredMinRep")
    if type(rep) == "table" and rep[1] then
        out[#out + 1] = ("needs a reputation standing with a faction (faction id %s)"):format(tostring(rep[1]))
    end
    return out, refs
end

-- Used by QuestShare.lua. Reasons a teammate (or me, when who is nil) can't take a quest right now,
-- as a list of sentences - empty when nothing is known to stop them, nil when QuestieDB isn't there.
function ns.QuestName(id)
    local lib = Lib()
    return lib and Get(lib.Quest, id, "name") or nil
end

-- Where a quest is given: every spawn point (up to 12) of the NPCs / objects that start it, as
-- { name, uiMap, x, y } with x, y in map percent; and the level it needs. Used by MapQuestHints.lua.
local giverCache = {}
function ns.QuestGiverPoints(id)
    local c = giverCache[id]
    if c then return c.points, c.level end
    local lib = Lib()
    if not lib then return {}, nil end
    local points = {}
    local sb = Get(lib.Quest, id, "startedBy")
    local faction = (UnitFactionGroup("player") or ""):sub(1, 1)
    local areaMap = ns.LoadAreaMap and ns.LoadAreaMap() or {}
    local function Add(db, objId, checkFaction)
        if not db then return end
        if checkFaction then
            local friendly = Get(db, objId, "friendlyToFaction")
            if type(friendly) == "string" and faction ~= "" and not friendly:find(faction, 1, true) then return end
        end
        local name = Get(db, objId, "name")
        local spawns = Get(db, objId, "spawns")
        if type(spawns) ~= "table" then return end
        for area, pts in pairs(spawns) do
            local uiMap = areaMap[area]
            if uiMap and uiMap ~= 0 and type(pts) == "table" then
                for _, pt in ipairs(pts) do
                    if #points < 12 and pt[1] and pt[2] and pt[1] >= 0 and pt[2] >= 0 then
                        points[#points + 1] = { name = name, uiMap = uiMap, x = pt[1], y = pt[2] }
                    end
                end
            end
        end
    end
    if type(sb) == "table" then
        for _, npc in ipairs(type(sb[1]) == "table" and sb[1] or {}) do Add(lib.Npc, npc, true) end
        for _, obj in ipairs(type(sb[2]) == "table" and sb[2] or {}) do Add(lib.Object, obj, false) end
    end
    local level = Get(lib.Quest, id, "requiredLevel")
    if type(level) ~= "number" or level < 1 then level = nil end
    giverCache[id] = { points = points, level = level }
    return points, level
end

function ns.WhyCantTake(id, who)
    local lib = Lib()
    if not lib then return nil end
    if who == nil then
        who = Me(); who.checkPrereqs = true
    end
    return Blockers(lib, id, who)
end

-- Quest ids whose "finished" status decides whether someone can take this quest (earlier quests in the
-- chain, exclusive quests, the parent), so QuestShare can have every player report them.
local relatedCache = {}
function ns.QuestRelated(id)
    if relatedCache[id] then return relatedCache[id] end
    local list = {}
    local lib = Lib()
    if lib then
        for _, field in ipairs({ "preQuestGroup", "preQuestSingle", "exclusiveTo" }) do
            for _, x in ipairs(IdList(Get(lib.Quest, id, field))) do list[#list + 1] = x end
        end
        local parent = Get(lib.Quest, id, "parentQuest")
        if type(parent) == "number" and parent > 0 then list[#list + 1] = parent end
        relatedCache[id] = list   -- only cache real answers (not "QuestieDB isn't ready yet")
    end
    return list
end

---------------------------------------------------------------------------
-- The chain of quests before it
---------------------------------------------------------------------------

local function Prereqs(lib, id)
    return IdList(Get(lib.Quest, id, "preQuestGroup")), IdList(Get(lib.Quest, id, "preQuestSingle"))
end

-- Indented lines for every quest you'd need first (and what you'd need before those).
local function Tree(lib, id, depth, lines, seen)
    local group, single = Prereqs(lib, id)
    local pad = string.rep("    ", depth)
    local function Row(pid, prefix)
        lines[#lines + 1] = ("%s%s%s  %s"):format(pad, prefix, QName(lib, pid), Status(pid))
        if not Done(pid) and not InLog(pid) and depth < MAX_DEPTH and not seen[pid] then
            seen[pid] = true
            Tree(lib, pid, depth + 1, lines, seen)
        end
    end
    for _, pid in ipairs(group) do Row(pid, "") end
    if #single == 1 then
        Row(single[1], "")
    elseif #single > 1 then
        lines[#lines + 1] = pad .. "|cff808080any one of:|r"
        for _, pid in ipairs(single) do Row(pid, "- ") end
    end
end

-- The quest you can actually pick up (or finish) right now on the way to id.
-- Returns { id =, kind = "log" | "start" }, or nil when id itself is done.
local function NextStep(lib, id, seen)
    if Done(id) then return nil end
    if InLog(id) then return { id = id, kind = "log" } end
    if seen[id] then return { id = id, kind = "start" } end
    seen[id] = true
    local group, single = Prereqs(lib, id)
    for _, pid in ipairs(group) do
        if not Done(pid) then
            local s = NextStep(lib, pid, seen)
            if s then return s end
        end
    end
    if #single > 0 then
        local anyDone = false
        for _, pid in ipairs(single) do if Done(pid) then anyDone = true end end
        if not anyDone then
            for _, pid in ipairs(single) do if InLog(pid) then return { id = pid, kind = "log" } end end
            local s = NextStep(lib, single[1], seen)
            if s then return s end
        end
    end
    return { id = id, kind = "start" }
end

---------------------------------------------------------------------------
-- Who gives a quest, and where they are
---------------------------------------------------------------------------

local function PlayerWorld()
    local map = C_Map and C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    return C_Map.GetWorldPosFromMapPos(map, pos)
end

-- Nearest spawn point in a QuestieDB spawns table ({ [areaId] = { {x, y}, ... } }).
local function NearestSpawn(spawns)
    if type(spawns) ~= "table" then return end
    local areaMap = ns.LoadAreaMap and ns.LoadAreaMap() or {}
    local myCont, myPos = PlayerWorld()
    local best, other
    for area, points in pairs(spawns) do
        local uiMap = areaMap[area]
        if uiMap and uiMap ~= 0 and type(points) == "table" then
            for _, pt in ipairs(points) do
                local x, y = pt[1], pt[2]
                if x and y and x >= 0 and y >= 0 then
                    local cand = { uiMap = uiMap, x = x, y = y }
                    local cont, wpos = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(x / 100, y / 100))
                    if myCont and cont == myCont and wpos then
                        local dx, dy = wpos.x - myPos.x, wpos.y - myPos.y
                        cand.dist = math.sqrt(dx * dx + dy * dy)
                        if not best or cand.dist < best.dist then best = cand end
                    elseif not other then
                        other = cand
                    end
                end
            end
        end
    end
    return best or other
end

-- Returns a list of giver descriptions and the best place to point at.
local function Starters(lib, id)
    local sb = Get(lib.Quest, id, "startedBy")
    local gives, bestPlace = {}, nil
    if type(sb) ~= "table" then return gives, nil end
    local faction = (UnitFactionGroup("player") or ""):sub(1, 1)

    local function Consider(db, objId, label)
        local name = Get(db, objId, "name") or (label .. " " .. objId)
        local friendly = Get(db, objId, "friendlyToFaction")
        if type(friendly) == "string" and faction ~= "" and not friendly:find(faction, 1, true) then return end
        local place = NearestSpawn(Get(db, objId, "spawns"))
        local entry = { name = name, place = place }
        gives[#gives + 1] = entry
        if place and (not bestPlace or (place.dist and (not bestPlace.dist or place.dist < bestPlace.dist))) then
            bestPlace = place
            bestPlace.name = name
        end
    end
    for _, npc in ipairs(type(sb[1]) == "table" and sb[1] or {}) do Consider(lib.Npc, npc, "NPC") end
    if lib.Object then
        for _, obj in ipairs(type(sb[2]) == "table" and sb[2] or {}) do Consider(lib.Object, obj, "object") end
    end
    if lib.Item then
        for _, item in ipairs(type(sb[3]) == "table" and sb[3] or {}) do
            gives[#gives + 1] = { name = Get(lib.Item, item, "name") or ("item " .. item), isItem = true }
        end
    end
    return gives, bestPlace
end

local function ZoneName(uiMap)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(uiMap)
    return info and info.name or ("map " .. uiMap)
end

local function DescribeStarters(gives)
    local lines = {}
    for i, g in ipairs(gives) do
        if i > 4 then lines[#lines + 1] = ("   ...and %d more"):format(#gives - 4); break end
        if g.isItem then
            lines[#lines + 1] = ("   starts from the item \"%s\""):format(g.name)
        elseif g.place then
            local s = ("   %s - %s %.1f, %.1f"):format(g.name, ZoneName(g.place.uiMap), g.place.x, g.place.y)
            if g.place.dist then s = s .. (" (~%d yd)"):format(g.place.dist) end
            lines[#lines + 1] = s
        else
            lines[#lines + 1] = ("   %s (location unknown)"):format(g.name)
        end
    end
    return lines
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

local panel, text, wayBtn
local wayPlace   -- where the waypoint button points

local function SetWaypoint()
    local p = wayPlace
    if not p then return end
    local placed = false
    if C_Map.SetUserWaypoint and UiMapPoint and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(p.uiMap)) then
        placed = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(p.uiMap, p.x / 100, p.y / 100))
        if placed and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
    local where = ("%s - %s %.1f, %.1f"):format(p.name or "quest giver", ZoneName(p.uiMap), p.x, p.y)
    ns:Print((placed and "Waypoint set: " or "Quest giver: ") .. where)
end

local function BuildPanel()
    panel = CreateFrame("Frame", "P13TweaksQuestGuide", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(PANEL_W, 200)
    panel:SetFrameStrata("DIALOG")
    panel:SetToplevel(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetClampedToScreen(true)
    tinsert(UISpecialFrames, panel:GetName())

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("How do I get this quest?")

    text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 14, -32)
    text:SetWidth(PANEL_W - 28)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(true)

    wayBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    wayBtn:SetSize(170, 24)
    wayBtn:SetPoint("BOTTOM", 0, 12)
    wayBtn:SetText("Set waypoint to quest giver")
    wayBtn:SetScript("OnClick", SetWaypoint)
end

local function ShowPanel(lines, place)
    if not panel then BuildPanel() end
    wayPlace = place
    text:SetText(table.concat(lines, "\n"))
    wayBtn:SetShown(place ~= nil)
    panel:SetHeight(text:GetStringHeight() + (place and 84 or 52))
    panel:ClearAllPoints()
    local anchor = _G.P13TweaksTeamQuests
    if anchor and anchor:IsShown() then
        panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    else
        panel:SetPoint("CENTER", 0, 80)
    end
    panel:Show()
    panel:Raise()
end

-- Opens the panel for a quest id. fallbackTitle is the name the teammate sent.
-- opts.forName: someone else needs this quest finished first (a prerequisite of what they can't take):
-- show where it starts, whatever my own progress on it is.
function ns.ShowQuestGuide(id, fallbackTitle, opts)
    local lib = Lib()
    if not lib then
        ShowPanel({ "|cffffd200" .. (fallbackTitle or ("Quest " .. id)) .. "|r", "",
            "This needs the QuestieDB addon (it knows who gives each quest and what comes before it).",
            "Install and enable QuestieDB, then try again." })
        return
    end
    local name = Get(lib.Quest, id, "name")
    if not name then
        ShowPanel({ "|cffffd200" .. (fallbackTitle or ("Quest " .. id)) .. "|r", "",
            ("QuestieDB has no record of quest %d, so I can't tell how to get it."):format(id) })
        return
    end

    local L = {}
    local qlevel = Get(lib.Quest, id, "questLevel")
    L[#L + 1] = "|cffffd200" .. name .. "|r" .. ((type(qlevel) == "number" and qlevel > 0) and ("  |cff808080(level " .. qlevel .. ")|r") or "")
    L[#L + 1] = ""

    if opts and opts.forName then
        L[#L + 1] = ("|cffffa040%s needs this quest finished first.|r"):format(opts.forName)
        local need = Get(lib.Quest, id, "requiredLevel")
        if type(need) == "number" and need > 1 then L[#L + 1] = ("It needs level %d."):format(need) end
        if Done(id) then
            L[#L + 1] = "|cff40ff40You've finished it yourself.|r It starts from:"
        elseif InLog(id) then
            L[#L + 1] = "|cff8fa8ffIt's in your log.|r It starts from:"
        else
            L[#L + 1] = "It starts from:"
        end
        local gives, best = Starters(lib, id)
        if #gives == 0 then
            L[#L + 1] = "   QuestieDB doesn't say who gives it."
        else
            for _, line in ipairs(DescribeStarters(gives)) do L[#L + 1] = line end
        end
        ShowPanel(L, best)
        return
    end

    if Done(id) then
        L[#L + 1] = "|cff40ff40You've already completed this quest.|r"
        ShowPanel(L); return
    end
    if InLog(id) then
        L[#L + 1] = "|cff8fa8ffYou already have this quest in your log.|r"
        ShowPanel(L); return
    end

    local blockers = Blockers(lib, id)
    if #blockers > 0 then
        L[#L + 1] = "|cffff6040You can't take it yet:|r"
        for _, b in ipairs(blockers) do L[#L + 1] = "   - " .. b end
    else
        L[#L + 1] = "|cff40ff40Nothing blocks you from taking it.|r"
    end
    L[#L + 1] = ""

    local tree = {}
    Tree(lib, id, 0, tree, { [id] = true })
    if #tree > 0 then
        L[#L + 1] = "|cffffd200Quests that come first:|r"
        for _, line in ipairs(tree) do L[#L + 1] = line end
    else
        L[#L + 1] = "|cffffd200No earlier quests are needed.|r"
    end
    L[#L + 1] = ""

    local step = NextStep(lib, id, {})
    local place
    if step and step.kind == "log" then
        L[#L + 1] = ("|cffffd200Next:|r finish \"%s\" - it's already in your log."):format(QName(lib, step.id))
    elseif step then
        if step.id == id then
            L[#L + 1] = "|cffffd200Next:|r pick it up from:"
        else
            L[#L + 1] = ("|cffffd200Next:|r start \"%s\" (it leads to this quest), from:"):format(QName(lib, step.id))
        end
        local gives, best = Starters(lib, step.id)
        place = best
        if #gives == 0 then
            L[#L + 1] = "   QuestieDB doesn't say who gives it."
        else
            for _, line in ipairs(DescribeStarters(gives)) do L[#L + 1] = line end
        end
        if step.id ~= id then
            local sb = Blockers(lib, step.id)
            if #sb > 0 then
                L[#L + 1] = "|cffff6040That one needs:|r"
                for _, b in ipairs(sb) do L[#L + 1] = "   - " .. b end
            end
        end
    end
    ShowPanel(L, place)
end

---------------------------------------------------------------------------
-- Option and command
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "questHow",
    type = "toggle",
    label = "Click a teammate's quest I don't have to see how to get it",
    tooltip = "In the teammates' quests window, clicking a quest you don't have opens a panel with what you'd need first (level, earlier quests in the chain), who gives it and where, with a waypoint button.\n\nNeeds QuestieDB.",
    default = true,
})

ns:RegisterCommand("questhow", "how to get a quest: /p13 questhow <questID>", function(arg)
    local id = tonumber(arg)
    if not id then ns:Print("Usage: /p13 questhow <quest id>  (or click a teammate's quest in /p13 quests)"); return end
    ns.ShowQuestGuide(id)
end)

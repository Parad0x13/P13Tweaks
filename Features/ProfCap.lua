-- P13Tweaks feature: on-screen notice when a profession is at or near its skill cap
-- (the most your current rank allows - time to visit a trainer for the next rank).
--
-- Reads GetProfessions() / GetProfessionInfo(), which give the current skill and the
-- current cap for each profession (primary, secondary, fishing, cooking...).
-- Left-click a line: waypoint to the nearest trainer for it (needs QuestieDB).
-- Drag the notice to move it. Right-click it to hide those lines until the cap changes
-- (so a profession at the game's absolute maximum doesn't stay on screen forever).
local ADDON_NAME, ns = ...

local DEFAULT_WITHIN = 5   -- show when this many points (or fewer) below the cap
local LINE_H = 16

---------------------------------------------------------------------------
-- Nearest trainer (QuestieDB, optional)
--
-- QuestieDB has every NPC's title ("Mining Trainer", "Expert Blacksmith"...), a trainer
-- flag, which faction it's friendly to, and where it stands. Trainers are matched on
-- their English title, so this only finds them on an English client.
---------------------------------------------------------------------------

-- skill line ID (GetProfessionInfo's 7th value) -> words a trainer's title contains
local PROF_WORDS = {
    [164] = { "blacksmith" },          [165] = { "leatherwork" },
    [171] = { "alchem" },              [197] = { "tailor" },
    [202] = { "engineer" },            [333] = { "enchant" },
    [182] = { "herbalis" },            [186] = { "mining", "miner" },
    [393] = { "skinn" },               [755] = { "jewelcraft" },
    [773] = { "inscription", "scribe" },
    [129] = { "first aid" },           [185] = { "cook", "chef" },
    [356] = { "fishing", "fisherman" },
}
-- Ranks in order; a cap of 75 means the next rank to learn is Journeyman, and so on.
local RANKS = { "apprentice", "journeyman", "expert", "artisan", "master", "grand master" }
local NEXT_RANK_BY_CAP = { [75] = 2, [150] = 3, [225] = 4, [300] = 5, [375] = 6 }

local TRAINER_FLAG = 16

-- Rank number named in a trainer's title ("expert blacksmith" -> 3), nil for "X Trainer".
local function TitleRank(sub)
    if sub:find("grand master", 1, true) then return 6 end
    for i = #RANKS - 1, 1, -1 do
        if sub:find(RANKS[i], 1, true) then return i end
    end
end

-- Class trainers are titled "<Class> Trainer"; they're stored under this key.
local CLASS_KEY = "CLASS"
-- Weapon masters (titled "Weapon Master") teach weapon skills; stored under this key.
-- Weapon skills were removed in Cataclysm, so this is only offered on older clients.
local WEAPON_KEY = "WEAPON"
-- General goods vendors (titled "General Goods" / "General Supplies"); stored under this key.
local GOODS_KEY = "GOODS"
local HAS_WEAPON_SKILLS = (select(4, GetBuildInfo()) or 0) < 40000

-- Weapon skills in menu order.
local WEAPONS = {
    "Bows", "Crossbows", "Daggers", "Fist Weapons", "Guns",
    "One-Handed Axes", "One-Handed Maces", "One-Handed Swords", "Polearms", "Staves",
    "Thrown", "Two-Handed Axes", "Two-Handed Maces", "Two-Handed Swords",
}
-- Which weapon master teaches what (WoW Forever / Classic; source: Warcraft Tavern's
-- Forever weapon trainer guide, matches warcraft.wiki.gg). Matched on the NPC's name.
local WEAPON_TEACHERS = {
    ["Woo Ping"]          = { "Crossbows", "Daggers", "One-Handed Swords", "Polearms", "Staves", "Two-Handed Swords" },
    ["Bixi Wobblebonk"]   = { "Crossbows", "Daggers", "Thrown" },
    ["Buliwyf Stonehand"] = { "Fist Weapons", "Guns", "One-Handed Axes", "One-Handed Maces", "Two-Handed Axes", "Two-Handed Maces" },
    ["Ilyenia Moonfire"]  = { "Bows", "Daggers", "Fist Weapons", "Staves", "Thrown" },
    ["Sayoc"]             = { "Bows", "Daggers", "Fist Weapons", "One-Handed Axes", "Staves", "Thrown", "Two-Handed Axes" },
    ["Hanashi"]           = { "Bows", "One-Handed Axes", "Staves", "Thrown", "Two-Handed Axes" },
    ["Ansekhwa"]          = { "Guns", "One-Handed Maces", "Staves", "Two-Handed Maces" },
    ["Archibald"]         = { "Crossbows", "Daggers", "One-Handed Swords", "Polearms", "Two-Handed Swords" },
}
local function Teaches(npcName, weapon)
    for _, w in ipairs(WEAPON_TEACHERS[npcName] or {}) do
        if w == weapon then return true end
    end
    return false
end
local function ClassWord()
    local _, token = UnitClass("player")
    return token == "DEATHKNIGHT" and "death knight" or (token or ""):lower()
end

local trainers      -- skillLine (or CLASS_KEY) -> { {id, name, sub, rank, spawns}, ... }, built once
local areaToUiMap   -- QuestieDB zone ID -> map ID

local function LoadAreaMap()
    if areaToUiMap then return areaToUiMap end
    areaToUiMap = {}
    local lib = _G.LibQuestieDB
    local zdb = lib and lib.Support and lib.Support.Get and lib.Support.Get("ZoneDB")
    local priv = zdb and zdb.private
    if not priv then return areaToUiMap end
    -- Stored as source text ("return {...}"); the override entries win.
    for _, field in ipairs({ "areaIdToUiMapId", "areaIdToUiMapIdOverride" }) do
        local src = priv[field]
        local t = src
        if type(src) == "string" and loadstring then
            local fn = loadstring(src)
            local ok, res = pcall(fn or error)
            t = ok and res or nil
        end
        if type(t) == "table" then
            for area, uiMap in pairs(t) do areaToUiMap[area] = uiMap end
        end
    end
    return areaToUiMap
end

local function BuildTrainers()
    if trainers then return trainers end
    local lib = _G.LibQuestieDB
    if not (lib and lib.Npc and lib.Npc.GetAllIds) then return nil end
    trainers = {}
    local Get = lib.Npc.Get
    local myFaction = (UnitFactionGroup("player") or ""):sub(1, 1)   -- "A" or "H"
    local classTitle = ClassWord() .. " trainer"
    for _, id in ipairs(lib.Npc.GetAllIds()) do
        local okF, flags = pcall(Get, id, "npcFlags")
        -- General goods vendors (not trainers): matched on their title alone.
        local _, gsub = pcall(Get, id, "subName")
        if type(gsub) == "string" then
            local lg = gsub:lower()
            if lg:find("general goods", 1, true) or lg:find("general supplies", 1, true) then
                local _, friendly = pcall(Get, id, "friendlyToFaction")
                local _, spawns = pcall(Get, id, "spawns")
                local _, name = pcall(Get, id, "name")
                if type(friendly) == "string" and friendly:find(myFaction, 1, true) and type(spawns) == "table" then
                    trainers[GOODS_KEY] = trainers[GOODS_KEY] or {}
                    table.insert(trainers[GOODS_KEY], { id = id, name = name or "?", sub = gsub, spawns = spawns })
                end
            end
        end
        if okF and type(flags) == "number" and bit.band(flags, TRAINER_FLAG) ~= 0 then
            local _, sub = pcall(Get, id, "subName")
            local _, friendly = pcall(Get, id, "friendlyToFaction")
            if type(sub) == "string" and type(friendly) == "string" and friendly:find(myFaction, 1, true) then
                local lsub = sub:lower()
                if classTitle ~= " trainer" and lsub:find(classTitle, 1, true) then
                    local _, spawns = pcall(Get, id, "spawns")
                    local _, name = pcall(Get, id, "name")
                    if type(spawns) == "table" then
                        trainers[CLASS_KEY] = trainers[CLASS_KEY] or {}
                        table.insert(trainers[CLASS_KEY], { id = id, name = name or "?", sub = sub, spawns = spawns })
                    end
                end
                if lsub:find("weapon master", 1, true) then
                    local _, spawns = pcall(Get, id, "spawns")
                    local _, name = pcall(Get, id, "name")
                    if type(spawns) == "table" then
                        local t = { id = id, name = name or "?", sub = sub, spawns = spawns }
                        trainers[WEAPON_KEY] = trainers[WEAPON_KEY] or {}
                        table.insert(trainers[WEAPON_KEY], t)
                        -- Also file them under each weapon they teach ("WEAPON:Daggers"...).
                        for _, w in ipairs(WEAPONS) do
                            if Teaches(t.name, w) then
                                local key = WEAPON_KEY .. ":" .. w
                                trainers[key] = trainers[key] or {}
                                table.insert(trainers[key], t)
                            end
                        end
                    end
                end
                for skillLine, words in pairs(PROF_WORDS) do
                    for _, w in ipairs(words) do
                        if lsub:find(w, 1, true) then
                            local _, spawns = pcall(Get, id, "spawns")
                            local _, name = pcall(Get, id, "name")
                            if type(spawns) == "table" then
                                trainers[skillLine] = trainers[skillLine] or {}
                                table.insert(trainers[skillLine], {
                                    id = id, name = name or "?", sub = sub,
                                    rank = TitleRank(lsub), spawns = spawns,
                                })
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    return trainers
end

-- Where the player is: continent ID and world position, or nil (e.g. inside a dungeon).
local function PlayerWorld()
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    return C_Map.GetWorldPosFromMapPos(map, pos)
end

-- Nearest trainer for one profession (p from Professions()). Returns the choice and a note.
local function FindTrainer(p)
    local list = BuildTrainers()
    if not list then return nil, "QuestieDB isn't installed or loaded, so trainer locations are unknown." end
    list = list[p.skillLine]
    if not list or #list == 0 then return nil, "No " .. p.name .. " trainer found for your faction in QuestieDB." end

    local need = NEXT_RANK_BY_CAP[p.max]
    local myCont, myPos = PlayerWorld()
    local areaMap = LoadAreaMap()
    local best, bestGeneric, anyOther   -- named-rank match / plain "X Trainer" / other continent

    for _, t in ipairs(list) do
        -- A trainer titled with a lower rank than you need can't teach it.
        local okRank = not (need and t.rank and t.rank < need)
        if okRank then
            for area, points in pairs(t.spawns) do
                local uiMap = areaMap[area]
                if uiMap and uiMap ~= 0 then
                    for _, pt in ipairs(points) do
                        local x, y = pt[1], pt[2]
                        if x and y and x >= 0 and y >= 0 then
                            local cont, wpos = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(x / 100, y / 100))
                            local cand = { t = t, uiMap = uiMap, x = x, y = y }
                            if myCont and cont == myCont and wpos then
                                local dx, dy = wpos.x - myPos.x, wpos.y - myPos.y
                                cand.dist = math.sqrt(dx * dx + dy * dy)
                                if t.rank then
                                    if not best or cand.dist < best.dist then best = cand end
                                elseif not bestGeneric or cand.dist < bestGeneric.dist then
                                    bestGeneric = cand
                                end
                            elseif not anyOther or (t.rank and not anyOther.t.rank) then
                                anyOther = cand
                            end
                        end
                    end
                end
            end
        end
    end

    -- For Journeyman any trainer works; from Expert up, a trainer titled with the rank
    -- is a safer bet than a plain "X Trainer" unless the plain one is much closer.
    local choice
    if need and need >= 3 then
        choice = best or bestGeneric
    else
        choice = (best and bestGeneric) and (best.dist < bestGeneric.dist and best or bestGeneric) or best or bestGeneric
    end
    local note
    if not choice and anyOther then
        choice = anyOther
        note = myCont and "No trainer on this continent - this one is elsewhere."
            or "Can't tell where you are right now (dungeon?), so this isn't necessarily the nearest."
    end
    if choice and need and need >= 3 and not choice.t.rank then
        note = "This trainer's title doesn't say they teach " .. RANKS[need]:gsub("^%l", string.upper)
            .. " - if they can't, ask a guard or try a capital city."
    end
    if not choice then return nil, "No reachable " .. p.name .. " trainer found." end
    return choice, note
end

local function GuideTo(p)
    local c, note = FindTrainer(p)
    if not c then ns:Print(note); return end
    local info = C_Map.GetMapInfo(c.uiMap)
    local zone = info and info.name or ("map " .. c.uiMap)
    local where = ("%s <%s> - %s %.1f, %.1f"):format(c.t.name, c.t.sub, zone, c.x, c.y)
    if c.dist then where = where .. (" (~%d yd)"):format(c.dist) end

    local placed = false
    if C_Map.SetUserWaypoint and UiMapPoint and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(c.uiMap)) then
        placed = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(c.uiMap, c.x / 100, c.y / 100))
        if placed and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
    ns:Print((placed and "Waypoint set: " or "Nearest trainer: ") .. where)
    if note then ns:Print("|cffffd200" .. note .. "|r") end
end

---------------------------------------------------------------------------
-- The notice
---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "P13TweaksProfCap", UIParent, "BackdropTemplate")
frame:SetSize(220, 40)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
if frame.SetBackdrop then
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
    frame:SetBackdropBorderColor(1, 0.82, 0, 0.9)
end
frame:Hide()

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -8)
title:SetText("Profession cap - visit a trainer")

local function Place()
    frame:ClearAllPoints()
    local p = P13TweaksDB.profCapPos
    if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint("TOP", UIParent, "TOP", 0, -140) end
end

local function StartDrag() frame:StartMoving() end
local function StopDrag()
    frame:StopMovingOrSizing()
    local point, _, relPoint, x, y = frame:GetPoint()
    P13TweaksDB.profCapPos = { point, relPoint, x, y }
end
frame:SetScript("OnDragStart", StartDrag)
frame:SetScript("OnDragStop", StopDrag)

local shown = {}   -- what's on screen now: { name, max }
local Update

local function DismissShown()
    P13TweaksDB.profCapDismissed = P13TweaksDB.profCapDismissed or {}
    for _, s in ipairs(shown) do P13TweaksDB.profCapDismissed[s.name] = s.max end
    Update()
end

local function ShowTip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Profession cap", 1, 1, 1)
    GameTooltip:AddLine("Left-click a profession: waypoint to the nearest trainer.", nil, nil, nil, true)
    GameTooltip:AddLine("Drag the title to move. Right-click to hide these until their cap goes up (after training).", nil, nil, nil, true)
    GameTooltip:Show()
end

frame:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then DismissShown() end end)
frame:SetScript("OnEnter", ShowTip)
frame:SetScript("OnLeave", GameTooltip_Hide)

-- One clickable row per profession.
local lines = {}
local function Line(i)
    if not lines[i] then
        local b = CreateFrame("Button", nil, frame)
        b:SetHeight(LINE_H)
        b:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4 - (i - 1) * LINE_H)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        b.text:SetPoint("LEFT")
        b.text:SetJustifyH("LEFT")
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")   -- no drag here: a drag would also click
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" then DismissShown() elseif self.prof then GuideTo(self.prof) end
        end)
        b:SetScript("OnEnter", ShowTip)
        b:SetScript("OnLeave", GameTooltip_Hide)
        lines[i] = b
    end
    return lines[i]
end

-- Every profession as { name, icon, level, max, skillLine }.
local function Professions()
    local list = {}
    if not (GetProfessions and GetProfessionInfo) then return list end
    for _, idx in pairs({ GetProfessions() }) do   -- pairs: the list can have holes
        local ok, name, icon, level, max, _, _, skillLine = pcall(GetProfessionInfo, idx)
        if ok and name and level and max and max > 0 then
            table.insert(list, { name = name, icon = icon, level = level, max = max, skillLine = skillLine })
        end
    end
    return list
end

Update = function()
    wipe(shown)
    if not P13TweaksDB or not ns:Get("profCap") then frame:Hide(); return end
    local within = ns:Get("profCapWithin") or DEFAULT_WITHIN
    local dismissed = P13TweaksDB.profCapDismissed or {}

    local n, width = 0, title:GetStringWidth()
    for _, p in ipairs(Professions()) do
        if dismissed[p.name] and dismissed[p.name] ~= p.max then dismissed[p.name] = nil end  -- trained: forget
        if p.max - p.level <= within and not dismissed[p.name] then
            n = n + 1
            local maxed = p.level >= p.max
            local color = maxed and "|cffff4040" or "|cffffa020"
            local icon = p.icon and ("|T" .. p.icon .. ":14:14:0:0|t ") or ""
            local b = Line(n)
            b.prof = p
            b.text:SetText(("%s%s  %s%d / %d|r%s"):format(icon, p.name, color, p.level, p.max,
                maxed and "  |cffff4040MAXED|r" or ""))
            local w = b.text:GetStringWidth()
            b:SetWidth(w)
            b:Show()
            width = math.max(width, w)
            table.insert(shown, { name = p.name, max = p.max })
        end
    end
    for i = n + 1, #lines do lines[i]:Hide(); lines[i].prof = nil end

    if n == 0 then frame:Hide(); return end
    frame:SetSize(width + 20, 30 + n * LINE_H)
    frame:Show()
end

---------------------------------------------------------------------------
-- "Mark closest Class Trainer" (plus one per profession) in the menu you get by
-- right-clicking your own portrait
---------------------------------------------------------------------------
local function GuideToClassTrainer()
    local className = UnitClass("player") or "Class"
    GuideTo({ name = className, skillLine = CLASS_KEY })   -- no cap: any class trainer will do
end

-- weapon = one of WEAPONS for a master who teaches it, or nil for the closest one of any kind.
local function GuideToWeaponMaster(weapon)
    if not HAS_WEAPON_SKILLS then ns:Print("This version of the game has no weapon masters."); return end
    if weapon then
        GuideTo({ name = weapon, skillLine = WEAPON_KEY .. ":" .. weapon })
    else
        GuideTo({ name = "Weapon Master", skillLine = WEAPON_KEY })
        ns:Print("|cffffd200Each weapon master teaches only some weapons - pick a weapon in the menu (or /p13 weapon <name>) to find one who teaches it.|r")
    end
end

local function GuideToGeneralGoods()
    GuideTo({ name = "General Goods", skillLine = GOODS_KEY })
end

-- Weapon skills you already have, from the character's skill list (English names).
local function KnownWeapons()
    local known = {}
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader = GetSkillLineInfo(i)
            if name and not isHeader then known[name] = true end
        end
    end
    return known
end

if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu("MENU_UNIT_SELF", function(_, root)
        if not ns:Get("classTrainerMenu") then return end
        root:CreateDivider()
        root:CreateButton("Mark closest Class Trainer", GuideToClassTrainer)
        root:CreateButton("Mark closest General Goods", GuideToGeneralGoods)
        if HAS_WEAPON_SKILLS then
            -- Submenu: one entry per weapon; ones you already know are greyed and marked.
            local sub = root:CreateButton("Mark closest Weapon Master")
            sub:CreateButton("Any weapon master", function() GuideToWeaponMaster() end)
            sub:CreateDivider()
            local known = KnownWeapons()
            for _, w in ipairs(WEAPONS) do
                local label = known[w] and ("|cff888888" .. w .. " (known)|r") or w
                sub:CreateButton(label, function() GuideToWeaponMaster(w) end)
            end
        end
        -- Read fresh each time the menu opens, so new/dropped professions show up.
        -- GuideTo uses the profession's cap to pick a trainer who teaches the next rank.
        for _, p in ipairs(Professions()) do
            if PROF_WORDS[p.skillLine] then
                local icon = p.icon and ("|T" .. p.icon .. ":14:14:0:0|t ") or ""
                root:CreateButton(icon .. "Mark closest " .. p.name .. " Trainer", function() GuideTo(p) end)
            end
        end
    end)
end

ns:RegisterOption({
    key = "profCap",
    type = "toggleNumber",
    label = "Profession cap notice",
    before = "Show professions within",
    after = "points of their cap",
    numberKey = "profCapWithin",
    numberDefault = DEFAULT_WITHIN,
    tooltip = "Puts a small notice on screen when a profession's skill is at its current cap (red, MAXED) or this many points below it (orange) - your cue to train the next rank. 0 = only when maxed.\n\nClick a profession in the notice for a waypoint to the nearest trainer (needs QuestieDB). Drag the notice to move it; right-click it to hide those professions until you train.",
    default = true,
    onChange = function() Update() end,
})

ns:RegisterOption({
    key = "classTrainerMenu",
    type = "toggle",
    label = "\"Mark closest Trainer\" items when right-clicking your portrait",
    tooltip = "Adds \"Mark closest Class Trainer\", \"Mark closest General Goods\", \"Mark closest Weapon Master\" (with a choice of weapon; only in games that still have weapon skills) and a \"Mark closest <Profession> Trainer\" for each of your professions to the menu you get by right-clicking your own portrait. Each puts a waypoint on the nearest matching trainer (needs QuestieDB). For a profession it looks for a trainer who teaches your next rank.",
    default = true,
})

ns:RegisterCommand("trainer", "waypoint to the nearest trainer for your class", GuideToClassTrainer)
ns:RegisterCommand("goods", "waypoint to the nearest General Goods vendor", GuideToGeneralGoods)
ns:RegisterCommand("weapon","waypoint to the nearest weapon master; /p13 weapon <weapon> (e.g. daggers, 2h swords) = nearest one who teaches it", function(arg)
    arg = strtrim(arg or ""):lower():gsub("^1h ", "one-handed "):gsub("^2h ", "two-handed ")
    if arg == "" then GuideToWeaponMaster(); return end
    for _, w in ipairs(WEAPONS) do
        if w:lower():find(arg, 1, true) then GuideToWeaponMaster(w); return end
    end
    ns:Print("Unknown weapon \"" .. arg .. "\". Choices: " .. table.concat(WEAPONS, ", "))
end)

ns:RegisterCommand("prof", "list your professions and caps; /p13 prof <name> = waypoint to its nearest trainer; /p13 prof reset = show dismissed notices again", function(arg)
    arg = strtrim(arg or ""):lower()
    if arg == "reset" then
        P13TweaksDB.profCapDismissed = nil
        Update()
        ns:Print("Dismissed profession notices cleared.")
        return
    end
    local list = Professions()
    if arg ~= "" then
        for _, p in ipairs(list) do
            if p.name:lower():find(arg, 1, true) then GuideTo(p); return end
        end
        ns:Print("You don't have a profession matching \"" .. arg .. "\".")
        return
    end
    if #list == 0 then ns:Print("No professions found.") end
    for _, p in ipairs(list) do ns:Print(("%s %d / %d"):format(p.name, p.level, p.max)) end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("SKILL_LINES_CHANGED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then Place() end
    Update()
end)

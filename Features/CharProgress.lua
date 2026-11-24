-- P13Tweaks feature: the "Character Progression" tab in /p13.
-- A plain-English page about the character you're logged in as: what your class and talent trees are for,
-- where your next talent points go (following a build plan, checked against your real talents), the buttons
-- worth pressing, what gear to look for, upgrades sitting in your bags, whether to visit the trainer, and
-- which zones have the most quests for your level right now.
--
-- Where the information comes from:
--   * your character, talents, gear, bags, spells and weapon skills: read live from the game
--   * the advice (builds, abilities, tips) per class: Features/CharProgressData.lua (researched for WoW Forever)
--   * gear scoring: RestedXP's WoW Forever stat weights when RXPGuides is loaded (read at runtime, not copied),
--     otherwise the simple weights in CharProgressData.lua
--   * zones: QuestieDB's quest list (WoW Forever's own quests) - counts quests at your level per zone
local ADDON_NAME, ns = ...

local DATA   -- ns.ProgressData, filled by CharProgressData.lua (loaded before this file)

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function CharKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end

local function Per(field)   -- per-character saved table
    P13TweaksDB[field] = P13TweaksDB[field] or {}
    return P13TweaksDB[field]
end

local function ClassColor()
    local _, token = UnitClass("player")
    local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS or {})[token]
    if c and c.colorStr then return "|c" .. c.colorStr end
    if c then return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

local GOLD, GREEN, GREY, RED, WHITE, BLUE = "|cffffd100", "|cff40ff40", "|cff9d9d9d", "|cffff5555", "|cffffffff", "|cff66bbff"
local R = "|r"

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local GetItemStats = (C_Item and C_Item.GetItemStats) or _G.GetItemStats

---------------------------------------------------------------------------
-- Talents (classic-style API: three trees, GetTalentInfo(tab, i) -> name, icon, tier, column, rank, maxRank)
---------------------------------------------------------------------------

-- WoW Forever doesn't use the old three-tab talent API: it shows the three classic trees
-- side by side in ONE modern talent tree (C_ClassTalents / C_Traits), and the old calls
-- read nothing there - so every point looked unspent. Trees are told apart by position
-- (a much wider gap between columns starts the next tree - same trick Leatrix Plus uses
-- on Forever), and the trees aren't named by the game, so names come from this table.
local TREE_NAMES = {
    WARRIOR = { "Arms", "Fury", "Protection" },        PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER  = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE   = { "Assassination", "Combat", "Subtlety" }, PRIEST = { "Discipline", "Holy", "Shadow" },
    SHAMAN  = { "Elemental", "Enhancement", "Restoration" }, MAGE = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" }, DRUID = { "Balance", "Feral Combat", "Restoration" },
}

local SpellName = (C_Spell and C_Spell.GetSpellName) or function(id) return (GetSpellInfo(id)) end

-- Fills t from the modern talent tree. Returns false if this client doesn't have one.
local function ReadTraitTalents(t)
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo) then return false end
    local okC, configID = pcall(C_ClassTalents.GetActiveConfigID)
    if not okC or not configID then return false end
    local config = C_Traits.GetConfigInfo(configID)
    local treeIDs = config and config.treeIDs
    if not (treeIDs and treeIDs[1]) then return false end

    local nodes = {}
    for _, treeID in ipairs(treeIDs) do
        for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
            local ok, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
            if ok and node and type(node.posX) == "number" and node.isVisible ~= false then
                local entryID = (node.activeEntry and node.activeEntry.entryID) or (node.entryIDs and node.entryIDs[1])
                local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
                local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
                local spellID = def and (def.spellID or def.overriddenSpellID)
                local name = (def and def.overrideName and def.overrideName ~= "" and def.overrideName)
                    or (spellID and SpellName(spellID))
                if name then
                    nodes[#nodes + 1] = { node = node, name = name, spellID = spellID }
                end
            end
        end
    end
    if #nodes == 0 then return false end

    -- purchased ranks (activeRank also counts ranks the game hands out for free)
    local anyBought = false
    for _, n in ipairs(nodes) do if (n.node.ranksPurchased or 0) > 0 then anyBought = true; break end end

    -- split columns into trees where the gap is much wider than the usual one
    local xsSet, xs = {}, {}
    for _, n in ipairs(nodes) do
        if not xsSet[n.node.posX] then xsSet[n.node.posX] = true; xs[#xs + 1] = n.node.posX end
    end
    table.sort(xs)
    local gaps = {}
    for i = 2, #xs do gaps[#gaps + 1] = xs[i] - xs[i - 1] end
    table.sort(gaps)
    local usualGap = gaps[math.ceil(#gaps / 2)] or 0
    local treeOfX, treeNo, colInTree = {}, 1, {}
    local col = 0
    for i, x in ipairs(xs) do
        if i > 1 and x - xs[i - 1] > usualGap * 1.5 then treeNo = treeNo + 1; col = 0 end
        col = col + 1
        treeOfX[x], colInTree[x] = treeNo, col
    end

    local _, classFile = UnitClass("player")
    local names = TREE_NAMES[classFile or ""] or {}
    for i = 1, treeNo do
        t.trees[i] = { name = names[i] or ("Tree " .. i), spent = 0, index = i, talents = {}, rows = {} }
    end
    -- rows: each tree's distinct heights, top to bottom = tier 1, 2, 3...
    for _, n in ipairs(nodes) do
        local tree = t.trees[treeOfX[n.node.posX]]
        tree.rows[n.node.posY or 0] = true
    end
    for _, tree in ipairs(t.trees) do
        local ys = {}
        for y in pairs(tree.rows) do ys[#ys + 1] = y end
        table.sort(ys)
        tree.rows = {}
        for i, y in ipairs(ys) do tree.rows[y] = i end
    end

    for _, n in ipairs(nodes) do
        local node = n.node
        local tree = t.trees[treeOfX[node.posX]]
        local rank = tonumber(anyBought and node.ranksPurchased or node.activeRank) or 0
        local e = { name = n.name, spellID = n.spellID, tier = tree.rows[node.posY or 0] or 1, column = colInTree[node.posX],
                    rank = rank, max = tonumber(node.maxRanks) or 0, tab = tree.index, index = node.ID, tree = tree }
        tree.talents[#tree.talents + 1] = e
        t.byName[n.name:lower()] = e
        tree.spent = tree.spent + rank
        t.spent = t.spent + rank
    end

    -- unspent points = the tree's talent currency
    if C_Traits.GetTreeCurrencyInfo then
        local ok, cur = pcall(C_Traits.GetTreeCurrencyInfo, configID, treeIDs[1], false)
        if ok and type(cur) == "table" and cur[1] and type(cur[1].quantity) == "number" then
            t.unspent = cur[1].quantity
        end
    end
    return true
end

local function ReadTalents()
    local t = { trees = {}, byName = {}, spent = 0 }
    if ReadTraitTalents(t) then
        local level = UnitLevel("player") or 1
        t.unspent = t.unspent or math.max(0, level - 9 - t.spent)
        local top
        for _, tree in ipairs(t.trees) do if not top or tree.spent > top.spent then top = tree end end
        t.top = (top and top.spent > 0) and top or nil
        return t
    end
    local nTabs = (GetNumTalentTabs and GetNumTalentTabs()) or 0
    for tab = 1, nTabs do
        -- the return list differs between clients (name first, or an id first): take the first string
        local info = { pcall(GetTalentTabInfo, tab) }
        local tname
        if info[1] then
            for k = 2, #info do if type(info[k]) == "string" then tname = info[k]; break end end
        end
        local tree = { name = tname or ("Tree " .. tab), spent = 0, index = tab, talents = {} }
        for i = 1, (GetNumTalents(tab) or 0) do
            local ok, name, icon, tier, column, rank, maxRank = pcall(GetTalentInfo, tab, i)
            if ok and type(name) == "string" then
                rank, maxRank = tonumber(rank) or 0, tonumber(maxRank) or 0
                local e = { name = name, icon = icon, tier = tier or 1, column = column, rank = rank, max = maxRank, tab = tab, index = i, tree = tree }
                tree.talents[#tree.talents + 1] = e
                t.byName[name:lower()] = e
                tree.spent = tree.spent + rank
            end
        end
        t.spent = t.spent + tree.spent
        t.trees[tab] = tree
    end
    local level = UnitLevel("player") or 1
    local unspent
    if GetUnspentTalentPoints then
        local ok, n = pcall(GetUnspentTalentPoints); if ok then unspent = tonumber(n) end
    end
    if not unspent and UnitCharacterPoints then
        local ok, n = pcall(UnitCharacterPoints, "player"); if ok then unspent = tonumber(n) end
    end
    t.unspent = unspent or math.max(0, level - 9 - t.spent)
    -- top tree
    local top
    for _, tree in ipairs(t.trees) do if not top or tree.spent > top.spent then top = tree end end
    t.top = (top and top.spent > 0) and top or nil
    return t
end

local function TreeByName(talents, name)
    if not name then return end
    name = name:lower()
    for _, tree in ipairs(talents.trees) do
        if tree.name:lower() == name then return tree end
    end
    for _, tree in ipairs(talents.trees) do   -- "Feral" vs "Feral Combat"
        local a = tree.name:lower()
        if a:find(name, 1, true) or name:find(a, 1, true) then return tree end
    end
end

-- The build's plan as steps: { name, target, have, max, entry, status = "done" | "todo" | "missing" }
local function PlanSteps(build, talents)
    local steps = {}
    for _, s in ipairs(build.points or {}) do
        local name, n = s:match("^(.-)%s+(%d+)$")
        name, n = name or s, tonumber(n) or 1
        local e = talents.byName[name:lower()]
        local step = { name = name, target = n, entry = e }
        if not e then
            step.status = "missing"
        else
            step.have, step.max = e.rank, e.max
            step.target = math.min(n, e.max > 0 and e.max or n)
            step.status = (e.rank >= step.target) and "done" or "todo"
        end
        steps[#steps + 1] = step
    end
    return steps
end

-- "Needs N more points in <tree>" when the talent's row isn't open yet, else nil
local function Locked(e)
    if not e then return end
    local need = ((e.tier or 1) - 1) * 5 - e.tree.spent
    if need > 0 then return need end
end

---------------------------------------------------------------------------
-- Which build plan to show: your pick (saved per character), else the one matching your top tree
---------------------------------------------------------------------------

local function ClassData()
    local _, token = UnitClass("player")
    return DATA and DATA.classes and DATA.classes[token], token
end

local function ChosenBuild(cls, talents)
    if not (cls and cls.builds and #cls.builds > 0) then return end
    local pick = Per("charProgressBuild")[CharKey()]
    if pick and cls.builds[pick] then return cls.builds[pick], pick end
    local level = UnitLevel("player") or 1
    local function Fits(b) return (level < 60) == (b.levelling and true or false) end
    if talents.top then
        for i, b in ipairs(cls.builds) do
            if Fits(b) and TreeByName(talents, b.tree) == talents.top then return b, i end
        end
        for i, b in ipairs(cls.builds) do
            if TreeByName(talents, b.tree) == talents.top then return b, i end
        end
    end
    for i, b in ipairs(cls.builds) do if Fits(b) then return b, i end end
    return cls.builds[1], 1
end

---------------------------------------------------------------------------
-- Gear scoring
---------------------------------------------------------------------------

local STAT_KEYS = {   -- short names used in CharProgressData weights -> GetItemStats keys
    STR = { "ITEM_MOD_STRENGTH_SHORT" }, AGI = { "ITEM_MOD_AGILITY_SHORT" }, STA = { "ITEM_MOD_STAMINA_SHORT" },
    INT = { "ITEM_MOD_INTELLECT_SHORT" }, SPI = { "ITEM_MOD_SPIRIT_SHORT" },
    AP = { "ITEM_MOD_ATTACK_POWER_SHORT" }, RAP = { "ITEM_MOD_RANGED_ATTACK_POWER_SHORT" },
    SP = { "ITEM_MOD_SPELL_POWER_SHORT", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT" }, HEAL = { "ITEM_MOD_SPELL_HEALING_DONE_SHORT" },
    HIT = { "ITEM_MOD_HIT_RATING_SHORT" }, CRIT = { "ITEM_MOD_CRIT_RATING_SHORT" }, HASTE = { "ITEM_MOD_HASTE_RATING_SHORT" },
    DEF = { "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT" }, DODGE = { "ITEM_MOD_DODGE_RATING_SHORT" },
    PARRY = { "ITEM_MOD_PARRY_RATING_SHORT" }, BLOCK = { "ITEM_MOD_BLOCK_RATING_SHORT", "ITEM_MOD_BLOCK_VALUE_SHORT" },
    MP5 = { "ITEM_MOD_MANA_REGENERATION_SHORT" }, HP5 = { "ITEM_MOD_HEALTH_REGEN_SHORT" },
    ARMOR = { "RESISTANCE0_NAME" }, DPS = { "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" },
}
local STAT_NAMES = {
    ITEM_MOD_STRENGTH_SHORT = "Strength", ITEM_MOD_AGILITY_SHORT = "Agility", ITEM_MOD_STAMINA_SHORT = "Stamina",
    ITEM_MOD_INTELLECT_SHORT = "Intellect", ITEM_MOD_SPIRIT_SHORT = "Spirit", ITEM_MOD_ATTACK_POWER_SHORT = "Attack Power",
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "Ranged Attack Power", ITEM_MOD_SPELL_POWER_SHORT = "Spell Power",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "Spell Damage", ITEM_MOD_SPELL_HEALING_DONE_SHORT = "Healing",
    ITEM_MOD_HIT_RATING_SHORT = "Hit", ITEM_MOD_CRIT_RATING_SHORT = "Crit", ITEM_MOD_HASTE_RATING_SHORT = "Haste",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "Defense", ITEM_MOD_DODGE_RATING_SHORT = "Dodge",
    ITEM_MOD_PARRY_RATING_SHORT = "Parry", ITEM_MOD_MANA_REGENERATION_SHORT = "Mana per 5 sec",
    ITEM_MOD_HEALTH_REGEN_SHORT = "Health per 5 sec",
}
-- shown in "best stats" only when the item stats are the plain ones a beginner sees on items
local MAIN_STATS = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STAMINA_SHORT",
    "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPIRIT_SHORT", "ITEM_MOD_ATTACK_POWER_SHORT", "ITEM_MOD_SPELL_POWER_SHORT",
    "ITEM_MOD_SPELL_HEALING_DONE_SHORT", "ITEM_MOD_HIT_RATING_SHORT", "ITEM_MOD_CRIT_RATING_SHORT",
    "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT", "ITEM_MOD_MANA_REGENERATION_SHORT" }

-- RestedXP's WoW Forever weights for this class / level / tree, if RXPGuides is loaded. RXP's own table is only read.
local function RXPWeights(token, level, treeName)
    local rxp = _G.RXP
    local all = type(rxp) == "table" and rxp.game == "FOREVER" and type(rxp.statWeights) == "table" and rxp.statWeights
    if not all then return end
    local lv = math.min(level, 59)
    local best, bestScore
    for _, d in pairs(all) do
        if type(d) == "table" and type(d.Class) == "string" and d.Class:upper() == token
            and (d.MIN_LEVEL or 0) <= lv and lv <= (d.MAX_LEVEL or 0) then
            local s = (tostring(d.Kind):upper() == "SPEEDRUN") and 1 or 0
            if treeName and type(d.Spec) == "string" and d.Spec:lower():find(treeName:lower(), 1, true) then s = s + 2 end
            if not bestScore or s > bestScore then best, bestScore = d, s end
        end
    end
    if not best then return end
    local w = {}
    for k, v in pairs(best) do if type(v) == "number" and k:find("^ITEM_MOD_") or k == "RESISTANCE0_NAME" then w[k] = v end end
    return w, best.Title and (best.Title .. (best.Spec and (" " .. best.Spec) or "")) or "RestedXP"
end

local function OwnWeights(build)
    local w = {}
    for short, v in pairs((build and build.weights) or {}) do
        for _, k in ipairs(STAT_KEYS[short] or {}) do w[k] = v end
        if short == "DPS" then w.ITEM_MOD_DAMAGE_PER_SECOND_SHORT_RANGED = w.ITEM_MOD_DAMAGE_PER_SECOND_SHORT_RANGED or v end
        if short == "RDPS" then w.ITEM_MOD_DAMAGE_PER_SECOND_SHORT_RANGED = v end
    end
    return w
end

local function Weights(build)
    local _, token = UnitClass("player")
    local w, src = RXPWeights(token, UnitLevel("player") or 1, build and build.tree)
    if not w then w, src = OwnWeights(build), "built-in" end
    -- A little value for armor, so plain white items (armor only, no stats) still compare
    -- instead of scoring 0. ~100 armor = 2 points, about one Agility for a hunter.
    if next(w) and not w.RESISTANCE0_NAME then w.RESISTANCE0_NAME = 0.02 end
    return w, src
end

local RANGED_LOC = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }

-- Stats written as green "Equip:" lines ("Equip: Increases attack power by 10.",
-- "Equip: Improves your chance to get a critical strike by 1%.") are often missing from
-- GetItemStats on classic-style items - so they were scored as nothing, while Pawn (which
-- reads the tooltip text) counted them. Read them from the item's tooltip text too.
local EQUIP_PATTERNS = {
    { "^Equip: Increases ranged attack power by (%d+)", "ITEM_MOD_RANGED_ATTACK_POWER_SHORT" },
    { "^Equip: %+(%d+) ranged Attack Power", "ITEM_MOD_RANGED_ATTACK_POWER_SHORT" },
    { "^Equip: Increases attack power by (%d+)", "ITEM_MOD_ATTACK_POWER_SHORT" },
    { "^Equip: %+(%d+) Attack Power", "ITEM_MOD_ATTACK_POWER_SHORT" },
    { "^Equip: Improves your chance to get a critical strike by (%d+)%%", "ITEM_MOD_CRIT_RATING_SHORT" },
    { "^Equip: Improves your chance to hit by (%d+)%%", "ITEM_MOD_HIT_RATING_SHORT" },
    { "^Equip: Restores (%d+) mana per 5 sec", "ITEM_MOD_MANA_REGENERATION_SHORT" },
    { "^Equip: Restores (%d+) health per 5 sec", "ITEM_MOD_HEALTH_REGEN_SHORT" },
    { "^Equip: Increases damage and healing done by magical spells and effects by up to (%d+)", "ITEM_MOD_SPELL_POWER_SHORT" },
    { "^Equip: Increases healing done by spells and effects by up to (%d+)", "ITEM_MOD_SPELL_HEALING_DONE_SHORT" },
    { "^Equip: Increases your chance to dodge an attack by (%d+)%%", "ITEM_MOD_DODGE_RATING_SHORT" },
    { "^Equip: Increased Defense %+(%d+)", "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT" },
}
local textBonusCache = {}
local function TextBonuses(link)
    local hit = textBonusCache[link]
    if hit then return hit end
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return {} end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
    if not ok or not data or not data.lines then return {} end   -- not cached yet: try again next time
    local out = {}
    for _, l in ipairs(data.lines) do
        local text = type(l.leftText) == "string" and l.leftText
        if text and text:find("^Equip:") then
            for _, p in ipairs(EQUIP_PATTERNS) do
                local n = tonumber(text:match(p[1]))
                if n then out[p[2]] = (out[p[2]] or 0) + n; break end
            end
        end
    end
    textBonusCache[link] = out
    return out
end

-- Score of an item for weights w. With `parts` (a table), also fills { {stat name, amount, points}, ... }.
local function Score(link, w, equipLoc, parts)
    local ok, stats = pcall(GetItemStats, link)
    if not ok or type(stats) ~= "table" then return nil end
    local all = {}
    for k, v in pairs(stats) do if type(v) == "number" then all[k] = v end end
    for k, v in pairs(TextBonuses(link)) do
        if not all[k] then all[k] = v end   -- only if the game didn't list it already
    end
    local s = 0
    local _, token = UnitClass("player")
    for k, v in pairs(all) do
        local pts = 0
        if k == "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" then
            if RANGED_LOC[equipLoc] then
                pts = v * (w.ITEM_MOD_DAMAGE_PER_SECOND_SHORT_RANGED or w[k] or 0)
            else
                -- a hunter's melee weapon is mostly a stat stick
                pts = v * (w[k] or 0) * (token == "HUNTER" and 0.15 or 1)
            end
        elseif w[k] then
            pts = v * w[k]
        end
        s = s + pts
        if parts and v ~= 0 then
            local name = (k == "RESISTANCE0_NAME" and "Armor") or (k == "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" and "Weapon DPS")
                or STAT_NAMES[k] or k:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", "")
            parts[#parts + 1] = { name, v, pts }
        end
    end
    if parts then table.sort(parts, function(a, b) return a[3] > b[3] end) end
    return s
end

-- equip location -> inventory slots it can go in
local SLOTS_OF = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}
local SLOT_NAMES = { "Head", "Neck", "Shoulders", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrists", "Hands",
    "Ring", "Ring", "Trinket", "Trinket", "Back", "Main hand", "Off hand", "Ranged" }

-- The game shows what you can't use in red on the tooltip (armor type, weapon skill, level, class).
local function IsRed(c) return c and c.r and c.r > 0.9 and c.g < 0.25 and c.b < 0.25 end
local function CanUseBagItem(bag, slot)
    if not (C_TooltipInfo and C_TooltipInfo.GetBagItem) then return true end
    local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
    if not ok or not data or not data.lines then return true end
    for _, line in ipairs(data.lines) do
        if IsRed(line.leftColor) or IsRed(line.rightColor) then return false end
    end
    return true
end

local function DualWields()
    if _G.CanDualWield then local ok, v = pcall(_G.CanDualWield); if ok then return v end end
    return false
end

-- Bag items that score higher than what's in their slot: { link, bag, slot, slotName, gain (0.15 = 15%), old }
local function BagUpgrades(w)
    local out, pending = {}, false
    if not (C_Container and C_Container.GetContainerNumSlots) then return out end
    local equipped = {}
    for inv = 1, 18 do
        local link = GetInventoryItemLink("player", inv)
        if link then
            local loc = select(9, GetItemInfo(link))
            equipped[inv] = { link = link, score = Score(link, w, loc) or 0, loc = loc }
        end
    end
    local dual = DualWields()
    for bag = 0, 4 do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local link = info and info.hyperlink
            if link then
                local _, _, quality, _, _, _, _, _, loc = GetItemInfo(link)
                if not loc then pending = true end
                local slots = loc and SLOTS_OF[loc]
                if slots and (quality or 0) >= 1 then
                    local score = Score(link, w, loc)
                    if not score then pending = true
                    elseif score > 0 and CanUseBagItem(bag, slot) then
                        -- compare with the weakest of the slots it can go in
                        local worstInv, worst
                        for _, inv in ipairs(slots) do
                            if not (inv == 17 and loc == "INVTYPE_WEAPON" and not dual) then
                                local e = equipped[inv]
                                local sc = e and e.score or 0
                                if inv == 17 and equipped[16] and equipped[16].loc == "INVTYPE_2HWEAPON" then sc = math.huge end
                                if not worst or sc < worst then worst, worstInv = sc, inv end
                            end
                        end
                        if loc == "INVTYPE_2HWEAPON" and equipped[17] then
                            worst = (equipped[16] and equipped[16].score or 0) + equipped[17].score
                        end
                        if worstInv and worst ~= math.huge and score > worst * 1.03 + 0.5 then
                            out[#out + 1] = { link = link, bag = bag, slot = slot, inv = worstInv, slotName = SLOT_NAMES[worstInv],
                                gain = worst > 0 and (score / worst - 1) or nil, old = equipped[worstInv] and equipped[worstInv].link }
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.gain or 99) > (b.gain or 99) end)
    return out, pending
end

---------------------------------------------------------------------------
-- Item tooltips: "P13: upgrade - about 12% better than your Hands"
-- Same scoring as the bag-upgrade check above, for any item you hover (bags, vendor,
-- quest rewards, loot, chat links).
---------------------------------------------------------------------------

local tipWeights, tipBuild, tipWeightsAt = nil, nil, 0
local function TipWeights()
    if not tipWeights or GetTime() - tipWeightsAt > 10 then   -- talents/level rarely change; don't redo per hover
        local ok, w, b = pcall(function()
            DATA = DATA or ns.ProgressData
            local build = ChosenBuild(ClassData(), ReadTalents())
            return (Weights(build)), build
        end)
        tipWeights, tipBuild, tipWeightsAt = ok and w or nil, ok and b or nil, GetTime()
    end
    return tipWeights, tipBuild
end

---------------------------------------------------------------------------
-- Stat tags on item tooltips: "+3 Agility  ★ best for you", "+2 Strength  useless for you"
-- Tiers come from the plan's plain ranking ("Agility > Attack Power > Intellect > Stamina"):
-- the first one is "best", the rest "good"; anything else the scoring values is "a little",
-- and stats worth (almost) nothing to you are "useless".
---------------------------------------------------------------------------

local STAT_BY_NAME = {}   -- "agility" -> "ITEM_MOD_AGILITY_SHORT"
for k, v in pairs(STAT_NAMES) do STAT_BY_NAME[v:lower()] = k end
STAT_BY_NAME["attack power"] = "ITEM_MOD_ATTACK_POWER_SHORT"
STAT_BY_NAME["crit"] = "ITEM_MOD_CRIT_RATING_SHORT"; STAT_BY_NAME["hit"] = "ITEM_MOD_HIT_RATING_SHORT"
local SAME_TIER = {   -- stats that count as the same thing for the tiers
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "ITEM_MOD_ATTACK_POWER_SHORT",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "ITEM_MOD_SPELL_POWER_SHORT",
}
local TAG_MARK = "|cff01ff01|r"   -- invisible marker so a line is never tagged twice

local function StatTier(key, w, build)
    local k = SAME_TIER[key] or key
    local listed = build and build.stats
    if listed then
        local i = 0
        for part in listed:gmatch("[^>]+") do
            i = i + 1
            local name = strtrim(part):lower():gsub("%s*%b()", "")
            local pk = STAT_BY_NAME[name]
            if pk and (SAME_TIER[pk] or pk) == k then return i == 1 and "best" or "good" end
        end
    end
    local v = w[key] or w[k] or 0
    if v <= 0 then return "useless" end
    -- per point vs your main stat; crit / hit / mana-per-5 come in small numbers, so they're never "useless"
    local main = 0
    for _, mk in ipairs({ "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPELL_POWER_SHORT" }) do
        main = math.max(main, w[mk] or 0)
    end
    local small = (k == "ITEM_MOD_CRIT_RATING_SHORT" or k == "ITEM_MOD_HIT_RATING_SHORT" or k == "ITEM_MOD_MANA_REGENERATION_SHORT")
    if small then return "good" end
    if main > 0 and v < main * 0.15 then return "useless" end
    return "little"
end

local TIER_TEXT = {
    best    = "  |TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12|t|cff40ff40 best for you|r",   -- (game font has no star glyph)
    good    = "  |cff40ff40good|r",
    little  = "  |cffffd200a little|r",
    useless = "  |cff9d9d9duseless for you|r",
}

local function TagStatLines(tooltip)
    if not ns:Get("charProgressStatTags") then return end
    local name = tooltip.GetName and tooltip:GetName()
    if not name then return end
    local w, build = TipWeights()
    if not (w and next(w)) then return end
    for i = 2, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and not text:find(TAG_MARK, 1, true) then
            local key
            local stat = text:match("^%+%d+ ([%a ]+)$")   -- "+3 Agility"
            if stat then key = STAT_BY_NAME[stat:lower()] end
            if not key and text:find("^Equip:") then
                for _, p in ipairs(EQUIP_PATTERNS) do
                    if text:match(p[1]) then key = p[2]; break end
                end
            end
            if key then fs:SetText(text .. TIER_TEXT[StatTier(key, w, build)] .. TAG_MARK) end
        end
    end
end

local GREEN_T, GREY_T, RED_T = "|cff40ff40", "|cff9d9d9d", "|cffff6060"

local function TooltipVerdict(link, lines)
    if not (link and ns:Get("charProgressTooltip")) then return end
    local loc = select(9, GetItemInfo(link))
    local slots = loc and SLOTS_OF[loc]
    if not slots then return end   -- not gear (grey gear still counts: it can beat an empty slot)
    -- the game colours what you can't use red (wrong armor type, class...). Too high a level
    -- is still compared - you'll want to know if it's worth keeping until then.
    local needLevel
    for _, l in ipairs(lines or {}) do
        if IsRed(l.leftColor) or IsRed(l.rightColor) then
            local lvl = type(l.leftText) == "string" and tonumber(l.leftText:match("^Requires Level (%d+)"))
            if lvl then needLevel = lvl else return end
        end
    end
    local later = needLevel and (" (once you're level " .. needLevel .. ")") or ""
    for _, inv in ipairs(slots) do   -- hovering something you're wearing: nothing to compare
        if GetInventoryItemLink("player", inv) == link then return end
    end
    local w = TipWeights()
    if not w then return end
    -- Hold Shift: list what was counted on this item and on the one it's compared with
    local why = IsShiftKeyDown() and {} or nil
    local function Explain(title, parts, total)
        if not why then return end
        why[#why + 1] = ("|cffffd200%s: %.1f points|r"):format(title, total or 0)
        if #parts == 0 then why[#why + 1] = GREY_T .. "   (no stats found)|r" end
        for _, p in ipairs(parts) do
            why[#why + 1] = ("%s   %s %s  = %.1f|r"):format(p[3] > 0 and "|cffffffff" or GREY_T,
                (p[1] == "Weapon DPS" and ("%.1f"):format(p[2]) or tostring(math.floor(p[2] + 0.5))), p[1], p[3])
        end
    end
    local myParts = why and {} or nil
    local score = Score(link, w, loc, myParts)
    if not score then return end   -- item data not loaded yet; the game re-shows the tooltip when it is
    if score <= 0 then return GREY_T .. "P13: nothing on it that helps you|r" end
    if why then Explain("This item", myParts, score) end

    local eqParts = {}
    local function EqScore(inv)
        local l = GetInventoryItemLink("player", inv)
        if not l then return nil end
        local parts = why and {} or nil
        local sc = Score(l, w, (select(9, GetItemInfo(l))), parts) or 0
        eqParts[inv] = { link = l, parts = parts, score = sc }
        return sc
    end
    local dual = DualWields()
    local worstInv, worst, empty
    for _, inv in ipairs(slots) do
        if not (inv == 17 and loc == "INVTYPE_WEAPON" and not dual) then
            local sc = EqScore(inv)
            if inv == 17 then
                local main = GetInventoryItemLink("player", 16)
                if main and select(9, GetItemInfo(main)) == "INVTYPE_2HWEAPON" then sc = math.huge end
            end
            if sc == nil then empty = empty or inv; sc = 0 end
            if sc ~= math.huge and (not worst or sc < worst) then worst, worstInv = sc, inv end
        end
    end
    if loc == "INVTYPE_2HWEAPON" then
        worst, worstInv = (EqScore(16) or 0) + (EqScore(17) or 0), 16
        empty = (not GetInventoryItemLink("player", 16)) and 16 or nil
    end
    if not worstInv then return end
    local slotName = SLOT_NAMES[worstInv]
    if why then
        local e = eqParts[worstInv]
        if e then Explain("Your " .. slotName .. " (" .. (GetItemInfo(e.link) or "?") .. ")", e.parts or {}, e.score)
        else why[#why + 1] = GREY_T .. "Your " .. slotName .. ": empty|r" end
    else
        why = { GREY_T .. "(hold Shift for the breakdown)|r" }
    end
    if empty and worst == 0 then
        return GREEN_T .. "P13: upgrade - you have nothing in " .. slotName .. later .. "|r", why
    end
    if worst <= 0 then return GREEN_T .. "P13: upgrade over your " .. slotName .. later .. "|r", why end
    local pct = math.floor((score / worst - 1) * 100 + 0.5)
    if pct >= 3 then
        return GREEN_T .. ("P13: upgrade +%d%% over your %s%s|r"):format(pct, slotName, later), why
    elseif pct > -3 then
        return GREY_T .. ("P13: about the same as your %s (%+d%%)%s|r"):format(slotName, pct, later), why
    else
        return RED_T .. ("P13: worse -%d%% vs your %s|r"):format(-pct, slotName), why
    end
end

local function OnItemTooltip(tooltip, data)
    local ok, _, link = pcall(tooltip.GetItem, tooltip)
    if not ok or not link then return end
    pcall(TagStatLines, tooltip)
    local okV, text, why = pcall(TooltipVerdict, link, data and data.lines)
    if okV and text then
        tooltip:AddLine(text)
        for _, l in ipairs(why or {}) do tooltip:AddLine(l) end
        tooltip:Show()   -- resize for the new lines
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip == GameTooltip or tooltip == ItemRefTooltip then OnItemTooltip(tooltip, data) end
    end)
else
    GameTooltip:HookScript("OnTooltipSetItem", function(self) OnItemTooltip(self, nil) end)
    if ItemRefTooltip then ItemRefTooltip:HookScript("OnTooltipSetItem", function(self) OnItemTooltip(self, nil) end) end
end

-- pressing / releasing Shift over an item redraws the tooltip, so the breakdown appears
local shiftWatch = CreateFrame("Frame")
shiftWatch:RegisterEvent("MODIFIER_STATE_CHANGED")
shiftWatch:SetScript("OnEvent", function(_, _, key)
    if not (key == "LSHIFT" or key == "RSHIFT") or not GameTooltip:IsShown() or not GameTooltip.RefreshData then return end
    local ok, _, link = pcall(GameTooltip.GetItem, GameTooltip)
    if ok and link then pcall(GameTooltip.RefreshData, GameTooltip) end
end)

local function TopStats(w, n)
    local list = {}
    for _, k in ipairs(MAIN_STATS) do if (w[k] or 0) > 0 then list[#list + 1] = k end end
    table.sort(list, function(a, b) return w[a] > w[b] end)
    local names = {}
    for i = 1, math.min(n, #list) do names[#names + 1] = STAT_NAMES[list[i]] end
    return names
end

---------------------------------------------------------------------------
-- Other checks: trainer, repairs, empty slots, weapon skills, spells known
---------------------------------------------------------------------------

local function TrainerDue()
    local level = UnitLevel("player") or 1
    local seen = Per("charProgressTrainer")[CharKey()]
    if not seen then return level >= 2, nil end
    for l = seen + 1, level do if l % 2 == 0 then return true, seen end end
    return false, seen
end

local function LowestDurability()
    local low, lowSlot
    for inv = 1, 18 do
        local cur, max = GetInventoryItemDurability(inv)
        if cur and max and max > 0 then
            local p = cur / max
            if not low or p < low then low, lowSlot = p, inv end
        end
    end
    return low, lowSlot
end

local IMPORTANT_EMPTY = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16 }
local function EmptySlots(cls)
    local level, out = UnitLevel("player") or 1, {}
    for _, inv in ipairs(IMPORTANT_EMPTY) do
        local early = (inv == 1 or inv == 2 or inv == 3 or inv == 11 or inv == 12) and level < 15
        if not early and not GetInventoryItemLink("player", inv) then out[#out + 1] = SLOT_NAMES[inv] end
    end
    if cls and cls.usesRanged and level >= 5 and not GetInventoryItemLink("player", 18) then out[#out + 1] = "Ranged" end
    return out
end

local function KnowsSpell(name)
    if not (C_Spell and C_Spell.GetSpellInfo) then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, name)
    if not ok or not info or not info.spellID then return false end
    -- (by name the game finds your highest known rank; if it also finds spells you don't have, these say no)
    if IsPlayerSpell then
        local ok2, k = pcall(IsPlayerSpell, info.spellID)
        if ok2 then return k and true or false, info.spellID end
    end
    if IsSpellKnown then
        local ok2, k = pcall(IsSpellKnown, info.spellID)
        if ok2 then return k and true or false, info.spellID end
    end
    return true, info.spellID
end

---------------------------------------------------------------------------
-- Zones: count QuestieDB quests at your level per zone (one chunked scan per session)
---------------------------------------------------------------------------

local quests, scanning   -- list of { id, lvl, req, zone, races, classes, maxl }
local onScanned = {}

local function QLib()
    local lib = _G.LibQuestieDB
    if lib and lib.Quest and lib.Quest.Get and lib.Quest.GetAllIds then return lib end
end

local function ScanQuests(done)
    if quests then if done then done() end return end
    if done then onScanned[#onScanned + 1] = done end
    if scanning then return end
    local lib = QLib()
    if not lib then return end
    local ok, ids = pcall(lib.Quest.GetAllIds)
    if not ok or type(ids) ~= "table" then return end
    scanning = true
    local list, i = {}, 1
    local function G(id, f) local ok2, v = pcall(lib.Quest.Get, id, f); if ok2 then return v end end
    local function Step()
        local last = math.min(#ids, i + 250)
        for k = i, last do
            local id = ids[k]
            local zone = G(id, "zoneOrSort")
            local lvl = G(id, "questLevel")
            if type(zone) == "number" and zone > 0 and type(lvl) == "number" and lvl > 0 then
                list[#list + 1] = { id = id, lvl = lvl, req = G(id, "requiredLevel"), zone = zone,
                    races = G(id, "requiredRaces"), classes = G(id, "requiredClasses"), maxl = G(id, "requiredMaxLevel") }
            end
        end
        i = last + 1
        if i <= #ids then C_Timer.After(0, Step) return end
        quests, scanning = list, nil
        local cbs = onScanned; onScanned = {}
        for _, f in ipairs(cbs) do pcall(f) end
    end
    Step()
end

local function Done(id)
    return C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id)
end

local dungeonArea
local function IsDungeonArea(zone)
    if not dungeonArea then
        dungeonArea = {}
        for _, d in ipairs(ns.DungeonList or {}) do for _, a in ipairs(d.areas or {}) do dungeonArea[a] = true end end
    end
    return dungeonArea[zone]
end

-- top zones: { { name, n, here } } for quests within [level-2, level+3] you can take and haven't done
local function ZonesForLevel()
    if not quests then return nil end
    local level = UnitLevel("player") or 1
    local _, _, raceId = UnitRace("player")
    local _, _, classId = UnitClass("player")
    local count = {}
    for _, q in ipairs(quests) do
        if q.lvl >= level - 2 and q.lvl <= level + 3 and (type(q.req) ~= "number" or q.req <= level + 1)
            and not (type(q.maxl) == "number" and q.maxl > 0 and level > q.maxl)
            and not (type(q.races) == "number" and q.races > 0 and raceId and raceId <= 31 and bit.band(q.races, bit.lshift(1, raceId - 1)) == 0)
            and not (type(q.classes) == "number" and q.classes > 0 and classId and classId <= 31 and bit.band(q.classes, bit.lshift(1, classId - 1)) == 0)
            and not IsDungeonArea(q.zone) and not Done(q.id) then
            count[q.zone] = (count[q.zone] or 0) + 1
        end
    end
    local list = {}
    local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local hereInfo = here and C_Map.GetMapInfo(here)
    for zone, n in pairs(count) do
        local name = C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(zone)
        if name and name ~= "" and n >= 2 then
            list[#list + 1] = { name = name, n = n, here = hereInfo and hereInfo.name == name }
        end
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    return list
end

---------------------------------------------------------------------------
-- The page: a scrolling list of lines and headings, rebuilt when shown / when something changes
---------------------------------------------------------------------------

local page, scroll, content, contentW
local linePool, used = {}, 0
local buttons = {}
local showAllPlan = false
local dirty = true

local function GetLine()
    used = used + 1
    local l = linePool[used]
    if not l then
        l = CreateFrame("Button", nil, content)
        l.fs = l:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l.fs:SetPoint("TOPLEFT")
        l.fs:SetJustifyH("LEFT")
        l.fs:SetJustifyV("TOP")
        l.fs:SetWordWrap(true)
        l.hl = l:CreateTexture(nil, "HIGHLIGHT")
        l.hl:SetAllPoints()
        l.hl:SetColorTexture(1, 1, 1, 0.06)
        l:SetScript("OnEnter", function(self)
            if not self.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local t = self.tip
            if t.link then GameTooltip:SetHyperlink(t.link)
            elseif t.talent then pcall(GameTooltip.SetTalent, GameTooltip, t.talent[1], t.talent[2])
            elseif t.spell then GameTooltip:SetSpellByID(t.spell)
            else
                GameTooltip:SetText(t.title or "", 1, 1, 1)
                if t.text then GameTooltip:AddLine(t.text, nil, nil, nil, true) end
            end
            if t.hint then GameTooltip:AddLine(t.hint, 0.2, 1, 0.6, true) end
            GameTooltip:Show()
        end)
        l:SetScript("OnLeave", GameTooltip_Hide)
        l:SetScript("OnClick", function(self) if self.tip and self.tip.click then self.tip.click() end end)
        linePool[used] = l
    end
    l:Show()
    return l
end

local y
local function Add(text, opts)
    opts = opts or {}
    local l = GetLine()
    local indent = opts.indent or 0
    l.fs:SetFontObject(opts.font or "GameFontHighlight")
    l.fs:SetWidth(contentW - indent - 4)
    l.fs:SetText(text)
    l.fs:SetTextColor(1, 1, 1)
    local h = math.max(l.fs:GetStringHeight(), 12)
    l:ClearAllPoints()
    l:SetPoint("TOPLEFT", content, "TOPLEFT", indent, y)
    l:SetSize(contentW - indent, h)
    l.tip = opts.tip
    l:EnableMouse(opts.tip ~= nil)
    y = y - h - (opts.gap or 3)
    return l
end

local function Heading(text)
    y = y - 8
    Add(GOLD .. text .. R, { font = "GameFontNormalLarge", gap = 4 })
end

local function Bullet(text, opts)
    opts = opts or {}
    opts.indent = (opts.indent or 0) + 10
    return Add("- " .. text, opts)
end

local function List(lines, indent)
    for _, s in ipairs(lines or {}) do Bullet(s, { indent = indent }) end
end

local function PlaceButton(key, text, w, onClick)
    local b = buttons[key]
    if not b then
        b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        b:SetHeight(20)
        buttons[key] = b
    end
    b:SetWidth(w)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", content, "TOPLEFT", 10, y)
    b:Show()
    return b
end

local Refresh

local function DrawPlan(build, talents)
    local steps = PlanSteps(build, talents)
    local total, doneN, missing = 0, 0, 0
    for _, s in ipairs(steps) do
        if s.status == "missing" then missing = missing + 1 else
            total = total + 1
            if s.status == "done" then doneN = doneN + 1 end
        end
    end
    -- the next few points, in order
    local shown = 0
    local want = showAllPlan and 999 or math.max(5, talents.unspent)
    local pointsAhead = 0
    for _, s in ipairs(steps) do
        if showAllPlan or (s.status == "todo" and shown < want) then
            local e = s.entry
            local line
            if s.status == "missing" then
                line = GREY .. s.name .. " - not in your talent trees (changed by a Forever patch?), skip it" .. R
            elseif s.status == "done" then
                line = GREEN .. "done  " .. R .. s.name .. GREY .. ("  %d/%d"):format(e.rank, e.max) .. R
            else
                local lock = Locked(e)
                local need = s.target - e.rank
                pointsAhead = pointsAhead + need
                line = (shown == 0 and (GOLD .. "NEXT  " .. R) or "      ") .. WHITE .. s.name .. R
                    .. GREY .. ("  %d/%d -> %d/%d  (%s)"):format(e.rank, e.max, s.target, e.max, e.tree.name) .. R
                if lock then line = line .. RED .. ("  opens after %d more point%s in %s"):format(lock, lock == 1 and "" or "s", e.tree.name) .. R end
                shown = shown + 1
            end
            Bullet(line, { tip = e and (e.spellID and { spell = e.spellID, hint = "Open your talents (N) and click this talent." }
                or { talent = { e.tab, e.index }, hint = "Open your talents (N) and click this talent." }) or nil })
        end
    end
    if doneN == total and total > 0 then
        Bullet(GREEN .. "You've finished this plan. Any leftover points: see the endgame build below." .. R)
    end
    -- points spent outside the plan
    local inPlan = {}
    for _, s in ipairs(steps) do if s.entry then inPlan[s.entry] = math.max(inPlan[s.entry] or 0, s.target) end end
    local off = {}
    for _, tree in ipairs(talents.trees) do
        for _, e in ipairs(tree.talents) do
            if e.rank > (inPlan[e] or 0) then off[#off + 1] = ("%s %d"):format(e.name, e.rank - (inPlan[e] or 0)) end
        end
    end
    if #off > 0 then
        Bullet(GREY .. "Points outside this plan: " .. table.concat(off, ", ")
            .. ". That's fine - it only means the plan's later points come a bit later. A respec at your class trainer resets them if you want." .. R)
    end
    if missing > 0 then
        Bullet(GREY .. ("%d talent name%s in this plan aren't in your trees and are skipped."):format(missing, missing == 1 and "" or "s") .. R)
    end
end

function Refresh()
    if not (content and page and page:IsVisible()) then dirty = true; return end
    dirty = false
    for i = 1, used do linePool[i]:Hide(); linePool[i].tip = nil end
    for _, b in pairs(buttons) do b:Hide() end
    used = 0
    y = -4
    contentW = content:GetWidth()

    local cls, token = ClassData()
    local talents = ReadTalents()
    local level = UnitLevel("player") or 1
    local race = UnitRace("player") or ""
    local className = UnitClass("player") or ""
    local faction = UnitFactionGroup("player") or ""

    Add(ClassColor() .. (UnitName("player") or "") .. R .. "  -  level " .. level .. " " .. race .. " " .. className
        .. GREY .. "  (" .. faction .. ")" .. R, { font = "GameFontNormalLarge", gap = 2 })
    if cls and cls.roles then Add(GREY .. "Can be: " .. R .. cls.roles, { gap = 2 }) end
    local split = {}
    for _, tree in ipairs(talents.trees) do split[#split + 1] = tree.spent end
    if #split > 0 then
        Add(GREY .. "Talent points: " .. R .. table.concat(split, " / ")
            .. (talents.top and (GREY .. "  (mostly " .. R .. talents.top.name .. GREY .. ")" .. R) or "")
            .. (talents.unspent > 0 and (GOLD .. ("   %d unspent!"):format(talents.unspent) .. R) or ""), { gap = 2 })
    end
    if not cls then
        Heading("No guide for this class yet")
        Bullet("There's no advice written for " .. className .. " (" .. tostring(token) .. ") yet.")
        content:SetHeight(-y + 10)
        return
    end

    local build, buildIdx = ChosenBuild(cls, talents)
    local w, wSrc = Weights(build)

    -------------------------------------------------- Do this now
    Heading("Do this now")
    local todo = 0
    if talents.unspent > 0 and level >= 10 then
        local nextStep
        for _, s in ipairs(PlanSteps(build, talents)) do if s.status == "todo" then nextStep = s; break end end
        todo = todo + 1
        Bullet(("You have %s%d talent point%s%s to spend. Press %sN%s to open your talents"):format(GOLD, talents.unspent,
            talents.unspent == 1 and "" or "s", R, GOLD, R)
            .. (nextStep and (" - next in your plan: " .. WHITE .. nextStep.name .. R .. " (" .. nextStep.entry.tree.name .. ").") or "."))
    end
    local ups, pending = BagUpgrades(w)
    for i, u in ipairs(ups) do
        if i > 4 then break end
        todo = todo + 1
        Bullet(("Wear %s from your bags (%s%s). %sClick to put it on.%s"):format(u.link, u.slotName,
            u.gain and (", about " .. math.floor(u.gain * 100 + 0.5) .. "% better") or ", the slot is empty", GREY, R),
            { tip = { link = u.link, hint = "Scored with " .. (wSrc or "?") .. " stat weights. Click to equip." }, })
        local l = linePool[used]
        l.tip.click = function()
            if InCombatLockdown() then ns:Print("can't change gear in combat.") return end
            if C_Container and C_Container.PickupContainerItem then
                ClearCursor()
                C_Container.PickupContainerItem(u.bag, u.slot)
                EquipCursorItem(u.inv)
                ClearCursor()
            end
        end
    end
    if pending then C_Timer.After(1, Refresh) end
    local due, seen = TrainerDue()
    if due then
        todo = todo + 1
        Bullet("Visit your " .. className .. " trainer in a city: " .. (seen and ("you've levelled since your last visit (level " .. seen .. ")") or "new spells come every 2 levels")
            .. ". Learn everything they offer - new ranks hit harder."
            .. ((C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("WhatsTraining")) and (GREY .. " (Your WhatsTraining tab in the spellbook lists exactly what.)" .. R) or "")
            .. GREY .. " Right-click your portrait > Mark closest Class Trainer." .. R)
    end
    local low, lowSlot = LowestDurability()
    if low and low < 0.3 then
        todo = todo + 1
        Bullet(RED .. ("Repair your gear soon (%s is at %d%%)."):format(SLOT_NAMES[lowSlot] or "?", math.floor(low * 100)) .. R .. " Any vendor with a hammer icon repairs.")
    end
    local empty = EmptySlots(cls)
    if #empty > 0 then
        todo = todo + 1
        Bullet("Nothing worn in: " .. table.concat(empty, ", ") .. ". Anything with your stats beats an empty slot - quest rewards, drops or the Auction House.")
    end
    -- (no weapon-skill check: WoW Forever replaced weapon skill with Expertise)
    if todo == 0 then Bullet(GREEN .. "Nothing urgent - keep questing!" .. R) end

    -------------------------------------------------- Build plan
    Heading("Your talent plan")
    if build then
        Add(WHITE .. build.name .. R .. (build.role and (GREY .. "  -  " .. build.role .. R) or ""), { indent = 4 })
        if build.why then Add(GREY .. build.why .. R, { indent = 4, font = "GameFontHighlightSmall" }) end
        local b1 = PlaceButton("plan", "Other plans (" .. buildIdx .. "/" .. #cls.builds .. ")", 150, function()
            local n = (buildIdx % #cls.builds) + 1
            Per("charProgressBuild")[CharKey()] = n
            Refresh()
        end)
        local b2 = buttons.all
        if not b2 then
            b2 = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
            b2:SetHeight(20); buttons.all = b2
        end
        b2:SetWidth(150)
        b2:SetText(showAllPlan and "Show next points only" or "Show the whole plan")
        b2:SetScript("OnClick", function() showAllPlan = not showAllPlan; Refresh() end)
        b2:ClearAllPoints(); b2:SetPoint("LEFT", b1, "RIGHT", 6, 0); b2:Show()
        y = y - 26
        if level < 10 then
            Bullet(GREY .. "Talents start at level 10 (one point every level after that). Here's where they'll go:" .. R)
        end
        DrawPlan(build, talents)
    end

    -------------------------------------------------- Buttons to press
    if build and build.rotation then
        Heading("How to fight")
        List(build.rotation)
    end
    if cls.abilities then
        Heading("Your key abilities")
        local list = {}
        for _, a in ipairs(cls.abilities) do list[#list + 1] = a end
        table.sort(list, function(a, b) return a[1] < b[1] end)
        for _, a in ipairs(list) do
            local lvl, name, how, approx = a[1], a[2], a[3], a[4] == "?"
            if lvl <= level + 6 then
                local known, sid = KnowsSpell(name)
                local tag
                if known then tag = GREEN .. "have  " .. R
                elseif lvl <= level and not approx then tag = GOLD .. "LEARN " .. R
                else tag = GREY .. (approx and "~lvl %d " or "lvl %d "):format(lvl) .. R end
                local when = approx and ("\n\nLearned from your class trainer at about level %d (not confirmed for Forever)."):format(lvl)
                    or ("\n\nLearned at level %d from your class trainer."):format(lvl)
                Bullet(tag .. WHITE .. name .. R .. GREY .. " - " .. how .. R, { tip = sid and { spell = sid } or { title = name, text = how .. when } })
            end
        end
    end

    -------------------------------------------------- Gear
    Heading("Gear: what to look for")
    if cls.armor then
        local now, later = {}, {}
        for _, a in ipairs(cls.armor) do
            if a[1] <= level then now[#now + 1] = a[2] else later[#later + 1] = a[2] .. " at level " .. a[1] end
        end
        Bullet("You can wear: " .. WHITE .. table.concat(now, ", ") .. R .. (#later > 0 and (GREY .. "  (" .. table.concat(later, ", ") .. ")" .. R) or ""))
    end
    if cls.weapons then Bullet("Weapons: " .. cls.weapons) end
    -- The plain ranking first. (Ranking the weights per POINT put crit / hit / mana-per-5 above
    -- Agility - true per point, but items give "+1% crit" vs "+10 Agility", so it misled.)
    if build and build.stats then
        Bullet("Best stats: " .. WHITE .. build.stats .. R)
    else
        local top = TopStats(w, 4)
        if #top > 0 then
            Bullet("Best stats (per point - crit and hit come in small numbers like +1%): " .. WHITE .. table.concat(top, " > ") .. R)
        end
    end
    Bullet("Not sure about an item? Hover it: the tooltip says if it's an upgrade and by about how much"
        .. GREY .. " (" .. (wSrc == "built-in" and "P13 scoring" or ("RestedXP weights: " .. wSrc)) .. ")" .. R)
    List(cls.gear)

    -------------------------------------------------- Where to level
    Heading("Where to level")
    local zones = ZonesForLevel()
    if zones then
        if #zones == 0 then
            Bullet(GREY .. "No quests left for your level in QuestieDB - try a dungeon, or the next level's zones." .. R)
        else
            for i, z in ipairs(zones) do
                if i > 5 then break end
                Bullet(WHITE .. z.name .. R .. GREY .. ("  -  %d quests for your level"):format(z.n) .. R .. (z.here and (GREEN .. "  (you're here)" .. R) or ""))
            end
            Add(GREY .. "Counted from QuestieDB: quests within a few levels of you that you haven't done and your race and class can take." .. R, { indent = 10, font = "GameFontHighlightSmall" })
        end
    elseif QLib() then
        Bullet(GREY .. "Counting quests..." .. R)
        ScanQuests(Refresh)
    end
    local myZones = DATA.zones and DATA.zones[faction]
    if myZones then
        local names = {}
        for _, z in ipairs(myZones) do
            if level >= z[1] - 1 and level <= z[2] then names[#names + 1] = z[3] .. GREY .. (" (%d-%d)"):format(z[1], z[2]) .. R end
        end
        if #names > 0 then Bullet("Usual zones for your level: " .. table.concat(names, ", ")) end
    end
    local dungeons = {}
    for _, d in ipairs(DATA.dungeons or {}) do
        if level >= d[1] - 2 and level <= d[2] then dungeons[#dungeons + 1] = d[3] .. GREY .. (" (%d-%d, %s)"):format(d[1], d[2], d[4]) .. R end
    end
    if #dungeons > 0 then Bullet("Dungeons for your level: " .. table.concat(dungeons, ", ") .. GREY .. ". Find a group with the Group Finder or in chat." .. R) end

    -------------------------------------------------- About your class
    Heading("Your class in one minute")
    if cls.intro then Add(cls.intro, { indent = 4 }) end
    for i, t in ipairs(cls.trees or {}) do
        local live = talents.trees[i]
        Bullet(WHITE .. (live and live.name or t.name) .. R .. GREY .. " - " .. R .. t.what .. GREY .. (t.best and ("  Best for: " .. t.best) or "") .. R)
    end
    if cls.endgame then
        Heading("At level 60")
        List(cls.endgame)
    end
    if cls.mistakes then
        Heading("Common mistakes")
        List(cls.mistakes)
    end
    if cls.forever then
        Heading("Different in WoW Forever")
        List(cls.forever)
    end
    if DATA.general then
        Heading("Good to know")
        for _, g in ipairs(DATA.general) do
            if (not g.max or level <= g.max) and (not g.min or level >= g.min) then Bullet(g.text) end
        end
    end
    y = y - 10
    Add(GREY .. "Advice gathered from WoW Forever guides (" .. (DATA.updated or "?") .. "). Forever is still being patched - if a talent name here doesn't exist in game, it's skipped." .. R,
        { font = "GameFontHighlightSmall" })
    content:SetHeight(-y + 10)
end

ns.customPages.charProgress = function(parent, top, width)
    DATA = ns.ProgressData
    page = parent
    scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, top)
    scroll:SetPoint("BOTTOMRIGHT", -30, 8)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width - 50, 10)
    scroll:SetScrollChild(content)
    contentW = width - 50
    parent:HookScript("OnShow", function() C_Timer.After(0, Refresh) end)
    if parent:IsVisible() then C_Timer.After(0, Refresh) end
end

---------------------------------------------------------------------------
-- Events: redraw while shown; remember trainer visits; level-up reminders in chat
---------------------------------------------------------------------------

local pendingRefresh
local function SoonRefresh()
    if pendingRefresh then return end
    pendingRefresh = true
    C_Timer.After(0.3, function() pendingRefresh = nil; if page and page:IsVisible() then Refresh() else dirty = true end end)
end

local announced = {}
local function Remind(reason)
    if not ns:Get("charProgressNotify") then return end
    DATA = ns.ProgressData
    local cls = ClassData()
    if not cls then return end
    local talents = ReadTalents()
    local build = ChosenBuild(cls, talents)
    if reason == "level" then
        local parts = {}
        if talents.unspent > 0 and (UnitLevel("player") or 1) >= 10 then
            local nextStep
            for _, s in ipairs(PlanSteps(build, talents)) do if s.status == "todo" then nextStep = s; break end end
            parts[#parts + 1] = ("%d talent point%s to spend%s"):format(talents.unspent, talents.unspent == 1 and "" or "s",
                nextStep and (" (next: " .. nextStep.name .. ")") or "")
        end
        if TrainerDue() then parts[#parts + 1] = "new spells at your class trainer" end
        if #parts > 0 then ns:Print("Level up! " .. table.concat(parts, "; ") .. ". Details: /p13 > Character Progression.") end
    elseif reason == "bags" then
        local ups = BagUpgrades((Weights(build)))
        for _, u in ipairs(ups) do
            if not announced[u.link] then
                announced[u.link] = true
                ns:Print(u.link .. " in your bags looks like an upgrade for your " .. u.slotName .. " - /p13 > Character Progression to equip it.")
            end
        end
    end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE",
    "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_DELAYED", "SKILL_LINES_CHANGED",
    "QUEST_TURNED_IN", "TRAINER_SHOW", "UPDATE_INVENTORY_DURABILITY",
    "TRAIT_CONFIG_UPDATED", "TRAIT_TREE_CURRENCY_INFO_UPDATED" }) do   -- (Forever's modern talent tree)
    pcall(ev.RegisterEvent, ev, e)
end
local bagsQuietUntil = 0
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        DATA = ns.ProgressData
        bagsQuietUntil = GetTime() + 10   -- don't announce what was already in the bags at login
        C_Timer.After(5, function() pcall(BagUpgrades, (Weights(ChosenBuild(ClassData(), ReadTalents())))) end)
        C_Timer.After(12, function()   -- remember what's already there so it isn't announced as new
            local ok, ups = pcall(BagUpgrades, (Weights(ChosenBuild(ClassData(), ReadTalents()))))
            if ok then for _, u in ipairs(ups) do announced[u.link] = true end end
        end)
        return
    end
    if event == "TRAINER_SHOW" then
        -- only class trainers count: the game's own test if it has one, else the NPC's title names your class
        local isClass
        if IsTradeskillTrainer then
            local ok, trade = pcall(IsTradeskillTrainer); isClass = ok and not trade
        else
            local className = UnitClass("player") or ""
            local ok, data = pcall(C_TooltipInfo.GetUnit, "npc")
            if ok and data and data.lines then
                for i = 2, math.min(#data.lines, 3) do
                    local t = data.lines[i].leftText
                    if type(t) == "string" and className ~= "" and t:find(className, 1, true) then isClass = true end
                end
            end
        end
        if isClass then Per("charProgressTrainer")[CharKey()] = UnitLevel("player") end
    elseif event == "PLAYER_LEVEL_UP" then
        C_Timer.After(1.5, function() pcall(Remind, "level") end)
    elseif event == "BAG_UPDATE_DELAYED" and GetTime() > bagsQuietUntil then
        C_Timer.After(0.5, function() pcall(Remind, "bags") end)
    end
    SoonRefresh()
end)

ns:RegisterOption({
    key = "charProgressNotify", type = "toggle", default = true,
    label = "Tell me in chat about talent points, trainer visits and bag upgrades",
    tooltip = "On level-up: how many talent points you have and where the next one goes in your plan, and whether your class trainer has new spells.\nWhen you loot or buy gear that scores better than what you wear: a chat line with the item.\n\nThe full picture is always on this tab.",
})

ns:RegisterOption({
    key = "charProgressTooltip", type = "toggle", default = true,
    label = "Item tooltips say if an item is an upgrade for you",
    tooltip = "Adds a line to item tooltips (bags, vendors, quest rewards, loot, chat links):\n|cff40ff40P13: upgrade +12% over your Hands|r\n|cff9d9d9dP13: about the same as your Hands (+1%)|r\n|cffff6060P13: worse -8% vs your Hands|r\n\nScored with your class and talent plan's stat values (or RestedXP's, if installed), plus a little for armor. Items too high level are still compared (\"once you're level 22\"); items you can't wear at all (wrong armor type, class) get no line. It's a guide, not exact maths.",
})

ns:RegisterOption({
    key = "charProgressStatTags", type = "toggle", default = true,
    label = "Item tooltips say which stats matter to you",
    tooltip = "Tags each stat line on an item:\n+3 Agility  |TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12|t|cff40ff40 best for you|r\n+5 Attack Power  |cff40ff40good|r\n+2 Spirit  |cffffd200a little|r\n+2 Strength  |cff9d9d9duseless for you|r\n\nBased on your class and talent plan (Character Progression tab).",
})

ns:RegisterCommand("build","open the Character Progression tab", function()
    local f = ns.optionsFrame
    if not f then return end
    f:Show()
    if ns.SelectOptionsTab then ns.SelectOptionsTab("Character Progression") end
end)

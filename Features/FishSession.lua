-- P13Tweaks feature: fishing session popup.
-- The first time you catch something while fishing, a small window opens showing how long you've been
-- fishing, how many things you've caught, and what all of it is worth right now (TradeSkillMaster's
-- regional sale average, "DBRegionSaleAvg", times the amount caught). Hover the window for the item list.
-- Closing the window ends the session: the next catch starts a new one from zero.
-- Needs TradeSkillMaster for the prices; without it the window still shows the time and the catch count.
-- Only items count (the little bit of coin you can fish up is ignored).
local ADDON_NAME, ns = ...

local PRICE_SOURCE = "DBRegionSaleAvg"
local PRICE_REFRESH = 5      -- seconds between price look-ups while the window is open
local START_SLACK = 120      -- a fishing cast this recent (seconds) counts as the start of the session

---------------------------------------------------------------------------
-- Session state
---------------------------------------------------------------------------

local active = false
local startTime = 0
local items = {}        -- [key] = { link =, count =, itemString =, unit = copper each or nil }
local order = {}        -- keys in the order first caught
local totalCount = 0
local lastCast = 0      -- when your last channelled cast began (fishing is one)
local win, timeText, caughtText, worthText, perHourText
local sinceTick, sinceRefresh = 0, 0

-- Copper as text like "1g 2s 33c" (parts that are zero are left out, except a lone "0c").
local function Coins(copper)
    copper = math.floor((copper or 0) + 0.5)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then table.insert(parts, "|cffffd700" .. g .. "g|r") end
    if s > 0 then table.insert(parts, "|cffc7c7cf" .. s .. "s|r") end
    if c > 0 or #parts == 0 then table.insert(parts, "|cffeda55f" .. c .. "c|r") end
    return table.concat(parts, " ")
end

local function Clock(seconds)
    seconds = math.max(0, math.floor(seconds))
    local h, m, s = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
    if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
    return ("%d:%02d"):format(m, s)
end

local function TSMPrice(it)
    if not (TSM_API and TSM_API.GetCustomPriceValue and TSM_API.ToItemString) then return nil end
    local ok, v = pcall(function()
        it.itemString = it.itemString or TSM_API.ToItemString(it.link)
        if not it.itemString then return nil end
        return TSM_API.GetCustomPriceValue(PRICE_SOURCE, it.itemString)
    end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function RefreshPrices()
    for _, it in pairs(items) do it.unit = TSMPrice(it) end
end

-- Total worth in copper, and how many caught things have no price.
local function Worth()
    local total, unpriced = 0, 0
    for _, it in pairs(items) do
        if it.unit then total = total + it.unit * it.count else unpriced = unpriced + it.count end
    end
    return total, unpriced
end

local function Update()
    if not (win and win:IsShown()) then return end
    timeText:SetText("Fishing for |cffffffff" .. Clock(GetTime() - startTime) .. "|r")
    caughtText:SetText("Caught |cffffffff" .. totalCount .. "|r")
    if not TSM_API then
        worthText:SetText("|cff999999TradeSkillMaster not found|r")
        perHourText:SetText("")
        return
    end
    local total, unpriced = Worth()
    local line = "Worth " .. Coins(total)
    if unpriced > 0 then line = line .. " |cff999999(" .. unpriced .. " without a price)|r" end
    worthText:SetText(line)
    -- A rate from the first few seconds would be wild, so wait a minute before showing one.
    local elapsed = GetTime() - startTime
    if elapsed >= 60 then
        perHourText:SetText("Per hour " .. Coins(total / (elapsed / 3600)))
    else
        perHourText:SetText("Per hour |cff999999...|r")
    end
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function Place()
    win:ClearAllPoints()
    local p = P13TweaksDB.fishSessionPos
    if p then
        win:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    end
end

local function EndSession()
    active = false
    items, order, totalCount = {}, {}, 0
end

local function BuildWindow()
    win = CreateFrame("Frame", "P13TweaksFishSession", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(260, 118)
    win:SetFrameStrata("MEDIUM")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        P13TweaksDB.fishSessionPos = { point, relPoint, x, y }
    end)
    Place()

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Fishing session")

    timeText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timeText:SetPoint("TOPLEFT", 14, -32)
    caughtText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    caughtText:SetPoint("TOPLEFT", timeText, "BOTTOMLEFT", 0, -6)
    worthText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    worthText:SetPoint("TOPLEFT", caughtText, "BOTTOMLEFT", 0, -6)
    perHourText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    perHourText:SetPoint("TOPLEFT", worthText, "BOTTOMLEFT", 0, -6)

    win:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Caught this session")
        for _, key in ipairs(order) do
            local it = items[key]
            local right = it.unit and (Coins(it.unit * it.count)) or "|cff999999no price|r"
            GameTooltip:AddDoubleLine(it.count .. "x " .. it.link, right, 1, 1, 1, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Prices: TSM " .. PRICE_SOURCE .. ". Close the window to start a new session.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    win:SetScript("OnLeave", function() GameTooltip:Hide() end)

    win:SetScript("OnUpdate", function(self, elapsed)
        sinceTick, sinceRefresh = sinceTick + elapsed, sinceRefresh + elapsed
        if sinceTick >= 1 then
            sinceTick = 0
            if sinceRefresh >= PRICE_REFRESH then sinceRefresh = 0; RefreshPrices() end
            Update()
        end
    end)

    -- Closing it (the X, or turning the option off) ends the session.
    win:SetScript("OnHide", EndSession)
end

local function AddCatch(link, count)
    if not ns:Get("fishSession") then return end
    if not win then BuildWindow() end
    if not active then
        active = true
        local now = GetTime()
        startTime = (now - lastCast <= START_SLACK) and lastCast or now
        items, order, totalCount = {}, {}, 0
        Place()
    end
    local key = link:match("item:(%d+)") or link
    local it = items[key]
    if not it then
        it = { link = link, count = 0 }
        items[key] = it
        table.insert(order, key)
    end
    it.count = it.count + count
    it.unit = TSMPrice(it)
    totalCount = totalCount + count
    sinceRefresh = 0
    if not win:IsShown() then win:Show() end
    Update()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- What the open fishing loot window holds, by slot: { link =, count = }. A slot counts as caught when
-- the game clears it (you took it, or auto-loot did).
local slots = {}
local debugOn = false
local function Dbg(...) if debugOn then ns:Print("fishsession: " .. strjoin(" ", tostringall(...))) end end

local fishingLoot = false   -- the open loot window is a fishing catch (sticks until it closes)

-- Remembers what's in the loot window. Called at LOOT_READY and LOOT_OPENED (whichever comes
-- first, before auto-loot has emptied it); slots already remembered are kept.
local function Snapshot(event)
    if IsFishingLoot and IsFishingLoot() then fishingLoot = true end
    local n = GetNumLootItems() or 0
    for i = 1, n do
        if not slots[i] then
            local link = GetLootSlotLink and GetLootSlotLink(i)
            if link and link:find("|Hitem:", 1, true) then
                local _, _, qty = GetLootSlotInfo(i)
                slots[i] = { link = link, count = tonumber(qty) or 1 }
            end
        end
    end
    local kept = 0
    for _ in pairs(slots) do kept = kept + 1 end
    Dbg(event, "- fishing loot:", fishingLoot, "- slots in window:", n, "- items remembered:", kept)
end

local events = CreateFrame("Frame")
events:RegisterEvent("LOOT_READY")
events:RegisterEvent("LOOT_OPENED")
events:RegisterEvent("LOOT_CLOSED")
events:RegisterEvent("LOOT_SLOT_CLEARED")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        lastCast = GetTime()
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        Snapshot(event)
    elseif event == "LOOT_SLOT_CLEARED" then
        local s = slots[arg1]
        Dbg("slot cleared", arg1, s and s.link or "(not an item we saw)", "- fishing loot:", fishingLoot)
        if s then
            slots[arg1] = nil
            if fishingLoot then AddCatch(s.link, s.count) end
        end
    elseif event == "LOOT_CLOSED" then
        Dbg("loot closed")
        slots, fishingLoot = {}, false
    end
end)

ns:RegisterCommand("fishsession", "fishing session window: /p13 fishsession test (fake catch), /p13 fishsession debug (print what it sees)", function(arg)
    arg = strtrim(arg or ""):lower()
    if arg == "debug" then
        debugOn = not debugOn
        ns:Print("Fishing session debug " .. (debugOn and "ON - go catch a fish." or "off."))
    elseif arg == "test" then
        AddCatch("|cffffffff|Hitem:6291::::::::1:::::::|h[Raw Brilliant Smallfish]|h|r", 1)
    else
        ns:Print(("Fishing session window is %s. TSM_API: %s. Try /p13 fishsession test or /p13 fishsession debug."):format(
            ns:Get("fishSession") and "on" or "OFF", TSM_API and "found" or "NOT found"))
    end
end)

ns:RegisterOption({
    key = "fishSession",
    type = "toggle",
    label = "Fishing session window (time, catch, worth)",
    tooltip = "When you catch something while fishing, a small window opens showing how long you've been fishing, how much you've caught, and what it's all worth right now at TradeSkillMaster's regional sale average (needs TradeSkillMaster). Hover it for the item list; drag it to move it. Close it and the next catch starts a new session.",
    default = true,
    onChange = function(v)
        if v == false and win and win:IsShown() then win:Hide() end
    end,
})

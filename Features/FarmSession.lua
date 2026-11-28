-- P13Tweaks feature: farming tracker.
-- Press Start, go kill things, and every item you loot from a mob (plus the coin they drop) is recorded.
-- The window shows two rough estimates of what the farm is worth, in total and per hour:
--   Vendor:  everything sold to a vendor (the item's sell price), plus the coin looted.
--   Auction: everything sold at the auction house's average sale price (TradeSkillMaster's regional sale
--            average, or Auctionator's price if TSM isn't there); items with no auction price (soulbound,
--            never seen on the AH) count at their vendor price, since that's what you'd do with them. Plus coin.
-- It also lists the most profitable kinds of mob (by NPC id): average loot value per kill, best first.
-- Stop pauses the clock and the recording (Start carries on from there). Finish saves the run as an "expedition"
-- in P13TweaksDB.farmHistory (listed in the Farming tab, FarmLog.lua) and starts a fresh one; /p13 farm reset
-- throws the current run away without saving it.
-- The session is saved, so it survives /reload and logging out (time logged out doesn't count).
-- Only loot whose source is a creature counts: not fishing, herbs, ore, chests or bag items (lockboxes, clams).
-- Skinning a mob does count (its source is the creature).
local ADDON_NAME, ns = ...

local TSM_SOURCE = "DBRegionSaleAvg"
local PRICE_REFRESH = 5      -- seconds between price look-ups while the window is open

---------------------------------------------------------------------------
-- Saved session: P13TweaksDB.farmSessionData
--   running  true while recording
--   elapsed  seconds recorded so far (only counts while running and logged in)
--   items    [itemID] = { link =, count = }
--   order    itemIDs in the order first looted
--   coin     copper looted from mobs
--   mobs     how many different mobs you looted
--   mobTypes [npcID] = { name =, kills =, coin =, items = { [itemID] = count },
--                        spots = { { instanceID, worldX, worldY }, ... } }  (per kind of mob; spots = kills)
--   zones    [zone name] = kills there
--   started  time() when first started
---------------------------------------------------------------------------

local function Data()
    local d = P13TweaksDB and P13TweaksDB.farmSessionData
    if type(d) ~= "table" then
        d = { running = false, elapsed = 0, items = {}, order = {}, coin = 0, mobs = 0 }
        if P13TweaksDB then P13TweaksDB.farmSessionData = d end
    end
    d.mobTypes = d.mobTypes or {}   -- (sessions saved by 0.31.21 didn't have it)
    d.zones = d.zones or {}         -- (nor this, before 0.31.25)
    return d
end

-- Saved expeditions, oldest first (see Finish).
local function History()
    if type(P13TweaksDB.farmHistory) ~= "table" then P13TweaksDB.farmHistory = {} end
    return P13TweaksDB.farmHistory
end

-- Which kills the heatmap (FarmHeat.lua) shows: P13TweaksDB.farmHeatSel = { exp = expedition id (nil = the
-- current run), npc = one kind of mob (nil = all of them) }, or nil for none.
function ns.FarmHeatIs(exp, npc)
    local s = P13TweaksDB.farmHeatSel
    return s ~= nil and s.exp == exp and s.npc == npc
end
local Update
function ns.FarmHeatToggle(exp, npc)
    P13TweaksDB.farmHeatSel = (not ns.FarmHeatIs(exp, npc)) and { exp = exp, npc = npc } or nil
    if ns.FarmHeatChanged then ns.FarmHeatChanged() end
    if Update then Update() end
    if ns.RefreshFarmLog then ns.RefreshFarmLog() end
end

-- The zone with the most kills in a zones table.
local function MainZone(zones)
    local best, bestN = nil, 0
    for z, n in pairs(zones or {}) do if n > bestN then best, bestN = z, n end end
    return best
end

local MOB_LINES = 5          -- best mobs shown in the window (/p13 farm mobs lists them all)
local MAX_SPOTS = 1000       -- kill positions kept per kind of mob (oldest dropped)

local priced = {}      -- [itemID] = { vendor = copper or nil, ah = copper or nil } (not saved; looked up again)
local seenMobs = {}    -- creature GUIDs already counted this play session
local win, statusText, lootText, coinText, vendorText, ahText, startBtn
local mobHeader, mobTexts = nil, {}
local body, collapseBtn      -- everything but the status line (hidden when collapsed), and the -/+ button
local BASE_H = 160           -- window height without the mob list
local COLLAPSED_H = 52       -- window height when collapsed (title bar + the status line)
local ticker
local sinceRefresh = 0

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

---------------------------------------------------------------------------
-- Prices
---------------------------------------------------------------------------

local function VendorPrice(link)
    local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, v = pcall(function() return select(11, get(link)) end)
    if ok and type(v) == "number" then return v end
    return nil   -- item not in the cache yet; asked again on the next refresh
end

local function AHName()
    if TSM_API and TSM_API.GetCustomPriceValue then return "TSM " .. TSM_SOURCE end
    if Auctionator and Auctionator.API and Auctionator.API.v1 then return "Auctionator" end
    return nil
end

local function AHPrice(link)
    if TSM_API and TSM_API.GetCustomPriceValue and TSM_API.ToItemString then
        local ok, v = pcall(function()
            local s = TSM_API.ToItemString(link)
            return s and TSM_API.GetCustomPriceValue(TSM_SOURCE, s)
        end)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemLink then
        local ok, v = pcall(api.GetAuctionPriceByItemLink, ADDON_NAME, link)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return nil
end

local function Price(id, link)
    local p = priced[id]
    if not p then p = {}; priced[id] = p end
    p.vendor = VendorPrice(link) or p.vendor
    p.ah = AHPrice(link) or p.ah
    return p
end

local function RefreshPrices()
    for id, it in pairs(Data().items) do Price(id, it.link) end
end

-- Totals in copper: vendor, auction, item count, items with no auction price.
local function Totals()
    local d = Data()
    local vendor, ah, count, noAH = d.coin, d.coin, 0, 0
    for id, it in pairs(d.items) do
        local p = priced[id] or Price(id, it.link)
        local v = (p.vendor or 0) * it.count
        vendor = vendor + v
        if p.ah then ah = ah + p.ah * it.count else ah = ah + v; noAH = noAH + it.count end
        count = count + it.count
    end
    return vendor, ah, count, noAH
end

-- Worth of one kind of mob's loot: vendor, auction (vendor price where there's no auction price), both + coin.
local function MobWorth(m)
    local vendor, ah = m.coin or 0, m.coin or 0
    local items = Data().items
    for id, n in pairs(m.items) do
        local it = items[id]
        local p = priced[id] or (it and Price(id, it.link)) or {}
        local v = (p.vendor or 0) * n
        vendor = vendor + v
        ah = ah + (p.ah and p.ah * n or v)
    end
    return vendor, ah
end

-- Every kind of mob looted, most profitable per kill first:
-- { name =, kills =, vendor =, ah =, perKill = } (perKill uses the auction value when there are auction prices).
local function MobRanking()
    local list, useAH = {}, AHName() ~= nil
    for npc, m in pairs(Data().mobTypes) do
        if (m.kills or 0) > 0 then
            local vendor, ah = MobWorth(m)
            local worth = useAH and ah or vendor
            table.insert(list, { npc = npc, spots = m.spots and #m.spots or 0, name = m.name or ("NPC " .. npc), kills = m.kills, vendor = vendor, ah = ah, perKill = worth / m.kills })
        end
    end
    table.sort(list, function(a, b)
        if a.perKill ~= b.perKill then return a.perKill > b.perKill end
        return a.kills > b.kills
    end)
    return list
end

local function MobLine(e)
    return ("%s |cff999999x%d|r  %s|cff999999/kill|r  |cff999999(%s)|r"):format(
        e.name, e.kills, Coins(e.perKill), Coins(AHName() and e.ah or e.vendor))
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function PerHour(total, elapsed)
    -- a rate from the first few seconds would be wild, so wait a minute before showing one
    if elapsed < 60 then return "|cff999999.../hr|r" end
    return Coins(total / (elapsed / 3600)) .. "|cff999999/hr|r"
end

Update = function()
    if not (win and win:IsShown()) then return end
    local d = Data()
    local status
    if d.running then
        status = "|cff33ff99Recording|r  " .. Clock(d.elapsed)
        startBtn:SetText("Stop")
    else
        status = (d.elapsed > 0 and "|cffffcc00Stopped|r  " or "|cff999999Not started|r  ") .. Clock(d.elapsed)
        startBtn:SetText(d.elapsed > 0 and "Resume" or "Start")
    end
    local vendor, ah, count, noAH = Totals()
    local collapsed = P13TweaksDB.farmSessionCollapsed
    body:SetShown(not collapsed)
    collapseBtn:SetNormalTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    collapseBtn:SetPushedTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Down" or "Interface\\Buttons\\UI-MinusButton-Down")
    if collapsed then
        -- one line: status, time and the gold per hour
        statusText:SetText(status .. "   " .. (AHName() and PerHour(ah, d.elapsed) or PerHour(vendor, d.elapsed)))
        win:SetHeight(COLLAPSED_H)
        return
    end
    statusText:SetText(status)
    lootText:SetText(("Looted |cffffffff%d|r items from |cffffffff%d|r mobs"):format(count, d.mobs))
    coinText:SetText("Coin  " .. Coins(d.coin))
    vendorText:SetText("Vendor  " .. Coins(vendor) .. "   " .. PerHour(vendor, d.elapsed))
    if AHName() then
        local line = "Auction  " .. Coins(ah) .. "   " .. PerHour(ah, d.elapsed)
        if noAH > 0 then line = line .. " |cff999999*|r" end
        ahText:SetText(line)
    else
        ahText:SetText("Auction  |cff999999needs TradeSkillMaster or Auctionator|r")
    end

    -- best mobs, per kill
    local ranking = MobRanking()
    mobHeader:SetText("Best mobs |cff999999(" .. (AHName() and "auction" or "vendor") .. " value per kill)|r")
    local shown = math.max(1, math.min(MOB_LINES, #ranking))
    for i = 1, MOB_LINES do
        local b = mobTexts[i]
        local e = ranking[i]
        b.npc = e and e.npc
        if e then
            b.text:SetText(i .. ". " .. MobLine(e))
        elseif i == 1 then
            b.text:SetText("|cff999999no mobs looted yet|r")
        else
            b.text:SetText("")
        end
        b.sel:SetShown(e ~= nil and ns.FarmHeatIs(nil, e.npc))
        b:SetShown(i <= shown)
    end
    win:SetHeight(BASE_H + 30 + shown * 15)
end

local function StartTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(1, function()
        local d = Data()
        if not d.running then return end
        d.elapsed = d.elapsed + 1
        sinceRefresh = sinceRefresh + 1
        if sinceRefresh >= PRICE_REFRESH and win and win:IsShown() then sinceRefresh = 0; RefreshPrices() end
        Update()
    end)
end

local function StopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end

local BuildWindow

local function ShowWindow()
    if not win then BuildWindow() end
    win:Show()
    RefreshPrices()
    Update()
end

local function Start()
    local d = Data()
    d.running = true
    d.started = d.started or time()
    StartTicker()
    if ns:Get("farmSession") then ShowWindow() else ns:Set("farmSession", true) end
    Update()
end

local function Stop()
    Data().running = false
    StopTicker()
    Update()
end

local function Reset()
    local d = Data()
    local wasRunning = d.running
    P13TweaksDB.farmSessionData = nil
    d = Data()
    d.running = wasRunning
    priced, seenMobs = {}, {}
    if ns.FarmHeatChanged then ns.FarmHeatChanged() end
    Update()
    if ns.RefreshFarmLog then ns.RefreshFarmLog() end
end

-- Saves the current run as an expedition (with prices as they are now) and starts a fresh, stopped one.
-- A run with nothing looted is just cleared.
local function Finish()
    local d = Data()
    if d.mobs == 0 and d.coin == 0 and not next(d.items) then
        Stop(); Reset()
        return nil
    end
    RefreshPrices()
    local vendor, ah, count, noAH = Totals()
    local hist = History()
    local id = (P13TweaksDB.farmNextId or (#hist + 1))
    P13TweaksDB.farmNextId = id + 1
    local e = {
        id = id, started = d.started, ended = time(), elapsed = d.elapsed,
        kills = d.mobs, items = count, coin = d.coin, vendor = vendor, ah = ah, noAH = noAH,
        priceSource = AHName(), zone = MainZone(d.zones), zones = d.zones,
        mobs = {}, spots = {}, loot = {},
    }
    for _, r in ipairs(MobRanking()) do
        table.insert(e.mobs, { npc = r.npc, name = r.name, kills = r.kills, vendor = r.vendor, ah = r.ah, perKill = r.perKill })
    end
    for npc, m in pairs(d.mobTypes) do
        if m.spots and #m.spots > 0 then e.spots[npc] = m.spots end
    end
    -- most valuable loot (for the tab's details)
    for id2, it in pairs(d.items) do
        local p = priced[id2] or {}
        local v = (p.vendor or 0) * it.count
        table.insert(e.loot, { link = it.link, count = it.count, value = p.ah and p.ah * it.count or v })
    end
    table.sort(e.loot, function(a, b) return a.value > b.value end)
    for i = #e.loot, 11, -1 do e.loot[i] = nil end
    table.insert(hist, e)
    -- a heatmap of the run you just finished keeps showing, now from the saved expedition
    local sel = P13TweaksDB.farmHeatSel
    if sel and sel.exp == nil then sel.exp = id end
    Stop()
    Reset()
    ns:Print(("Expedition saved: %s, %s, %d kills, Auction %s / Vendor %s. See /p13 > Farming."):format(
        e.zone or "?", Clock(e.elapsed), e.kills, Coins(ah), Coins(vendor)))
    return e
end

BuildWindow = function()
    win = CreateFrame("Frame", "P13TweaksFarmSession", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(360, BASE_H)
    win:SetFrameStrata("MEDIUM")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self.dragged = true; self:StartMoving() end)
    -- a plain click (not a drag) on the title bar collapses / expands, like the -/+ button
    win:SetScript("OnMouseDown", function(self) self.dragged = nil end)
    win:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" or self.dragged then return end
        local top = self:GetTop()
        local _, y = GetCursorPosition()
        y = y / self:GetEffectiveScale()
        if top and y <= top and y >= top - 24 then
            P13TweaksDB.farmSessionCollapsed = not P13TweaksDB.farmSessionCollapsed or nil
            Update()
        end
    end)
    -- (saved by the bottom-left corner, so expanding / growing pushes the title bar up and the bottom stays put)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local l, b = self:GetLeft(), self:GetBottom()
        if l and b then
            P13TweaksDB.farmSessionPos = { "BOTTOMLEFT", "BOTTOMLEFT", l, b }
            self:ClearAllPoints()
            self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
        end
    end)
    local p = P13TweaksDB.farmSessionPos
    if p then win:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else win:SetPoint("CENTER", UIParent, "CENTER", 0, 200) end
    if not p or p[1] ~= "BOTTOMLEFT" then
        -- (older saves / first show: re-anchor by the bottom-left corner once laid out, same as after a drag)
        C_Timer.After(0, function()
            local l, b = win:GetLeft(), win:GetBottom()
            if l and b then
                P13TweaksDB.farmSessionPos = { "BOTTOMLEFT", "BOTTOMLEFT", l, b }
                win:ClearAllPoints(); win:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
            end
        end)
    end

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Farming tracker")

    -- -/+ in the title bar (left of the close X): collapse to one line
    collapseBtn = CreateFrame("Button", nil, win)
    collapseBtn:SetSize(14, 14)
    collapseBtn:SetPoint("TOPRIGHT", -28, -5)
    collapseBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    collapseBtn:SetScript("OnClick", function()
        P13TweaksDB.farmSessionCollapsed = not P13TweaksDB.farmSessionCollapsed or nil
        Update()
    end)
    collapseBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(P13TweaksDB.farmSessionCollapsed and "Expand" or "Collapse to one line")
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", GameTooltip_Hide)

    statusText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("TOPLEFT", 14, -32)

    body = CreateFrame("Frame", nil, win)
    body:SetAllPoints(win)
    lootText = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lootText:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -6)
    coinText = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    coinText:SetPoint("TOPLEFT", lootText, "BOTTOMLEFT", 0, -6)
    vendorText = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    vendorText:SetPoint("TOPLEFT", coinText, "BOTTOMLEFT", 0, -6)
    ahText = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ahText:SetPoint("TOPLEFT", vendorText, "BOTTOMLEFT", 0, -6)

    mobHeader = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mobHeader:SetPoint("TOPLEFT", ahText, "BOTTOMLEFT", 0, -10)
    -- each mob line is a button: click it to show where you killed that mob on the map and minimap
    for i = 1, MOB_LINES do
        local b = CreateFrame("Button", nil, body)
        b:SetSize(334, 15)
        if i == 1 then b:SetPoint("TOPLEFT", mobHeader, "BOTTOMLEFT", 0, -2)
        else b:SetPoint("TOPLEFT", mobTexts[i - 1], "BOTTOMLEFT", 0, 0) end
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetAllPoints()
        b.sel:SetColorTexture(0.2, 1, 0.6, 0.18)
        b.sel:Hide()
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 6, 0)
        b.text:SetWidth(326)
        b.text:SetJustifyH("LEFT")
        b.text:SetWordWrap(false)
        b:SetScript("OnClick", function(self)
            if self.npc then ns.FarmHeatToggle(nil, self.npc) end
        end)
        b:SetScript("OnEnter", function(self)
            if not self.npc then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.text:GetText(), 1, 1, 1)
            local on = ns.FarmHeatIs(nil, self.npc)
            GameTooltip:AddLine(on and "Click to hide its kill heatmap."
                or "Click to show where you killed these, as a heatmap on the world map and minimap.", nil, nil, nil, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        mobTexts[i] = b
    end

    startBtn = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    startBtn:SetSize(80, 20)
    startBtn:SetPoint("BOTTOMLEFT", 12, 10)
    startBtn:SetScript("OnClick", function() if Data().running then Stop() else Start() end end)

    local finishBtn = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    finishBtn:SetSize(80, 20)
    finishBtn:SetPoint("LEFT", startBtn, "RIGHT", 6, 0)
    finishBtn:SetText("Finish")
    finishBtn:SetScript("OnClick", function() Finish() end)
    finishBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Finish this expedition", 1, 1, 1)
        GameTooltip:AddLine("Saves it to /p13 > Farming (where, how long, what it made, kill heatmap) and starts a fresh one. "
            .. "/p13 farm reset throws a run away without saving it.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    finishBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- the X hides the window (the option); recording carries on if it's running
    win:SetScript("OnHide", function()
        if ns:Get("farmSession") then ns:Set("farmSession", false) end
    end)
end

---------------------------------------------------------------------------
-- Recording loot
---------------------------------------------------------------------------

local debugOn = false
local function Dbg(...) if debugOn then ns:Print("farm: " .. strjoin(" ", tostringall(...))) end end

-- The mob GUID a loot slot came from, or nil if it isn't from a creature.
local function MobSource(slot)
    if not GetLootSourceInfo then return "?" end   -- old client: can't tell, count it
    local guid = GetLootSourceInfo(slot)
    if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then return nil end
    local kind = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return guid end
    return nil
end

local slots = {}          -- [slot] = { link =, count =, mob = guid } for the open loot window
local mobLootOpen = false -- the open loot window has something from a mob
local lastMoney           -- money when we started watching for looted coin (nil = not watching)

local coinMob             -- the first mob in the open loot window (looted coin is credited to it)

-- Mob names by GUID, learned whenever you target or mouse over a mob (and from both while looting).
-- (Not from the combat log: on this client an addon registering COMBAT_LOG_EVENT_UNFILTERED is blocked -
-- "P13Tweaks has been blocked from an action only available to the Blizzard UI", v0.31.23.)
-- GUIDs and names can be "secret" values, which may not be compared or used as table keys: those are skipped.
local names, nameCount = {}, 0
local function Secret(v) return issecretvalue and issecretvalue(v) end
local function RememberUnit(unit)
    local guid, name = UnitGUID(unit), UnitName(unit)
    if not (guid and name) or Secret(guid) or Secret(name) or name == "" or names[guid] then return end
    if nameCount > 500 then names, nameCount = {}, 0 end
    names[guid] = name
    nameCount = nameCount + 1
end
local function NameOf(guid)
    RememberUnit("target")
    RememberUnit("mouseover")
    return names[guid]
end

-- The kind-of-mob record for a creature GUID (its NPC id is the 6th part: Creature-0-x-x-x-npcID-spawn).
local function MobType(d, guid)
    if not guid or guid == "?" then return nil end
    local npc = select(6, strsplit("-", guid))
    if not npc then return nil end
    local m = d.mobTypes[npc]
    if not m then
        m = { kills = 0, coin = 0, items = {} }
        d.mobTypes[npc] = m
    end
    if not m.name then m.name = NameOf(guid) end
    return m
end

local function CountMob(d, guid)
    if guid and guid ~= "?" and not seenMobs[guid] then
        seenMobs[guid] = true
        d.mobs = d.mobs + 1
        local m = MobType(d, guid)
        local zone = GetZoneText and GetZoneText()
        if zone and zone ~= "" then d.zones[zone] = (d.zones[zone] or 0) + 1 end
        if m then
            m.kills = m.kills + 1
            -- where it died: your position while looting it (loot range is a few yards), in world yards
            local x, y, _, inst = UnitPosition("player")
            if x and inst and not (issecretvalue and (issecretvalue(x) or issecretvalue(y))) then
                m.spots = m.spots or {}
                if #m.spots >= MAX_SPOTS then table.remove(m.spots, 1) end
                table.insert(m.spots, { inst, math.floor(x + 0.5), math.floor(y + 0.5) })
                if ns.FarmHeatChanged then ns.FarmHeatChanged() end
            end
        end
    end
end

-- Remembers what's in the loot window. Called at LOOT_READY and LOOT_OPENED (whichever comes first,
-- before auto-loot has emptied it); slots already remembered are kept.
local function Snapshot(event)
    if IsFishingLoot and IsFishingLoot() then return end
    local d = Data()
    local n = GetNumLootItems() or 0
    for i = 1, n do
        local mob = MobSource(i)
        if mob then
            mobLootOpen = true
            coinMob = coinMob or mob
            if d.running then CountMob(d, mob) end   -- (also counts a mob that only dropped coin)
            if not slots[i] then
                local link = GetLootSlotLink and GetLootSlotLink(i)
                if link and link:find("|Hitem:", 1, true) then
                    local _, _, qty = GetLootSlotInfo(i)
                    slots[i] = { link = link, count = tonumber(qty) or 1, mob = mob }
                end
            end
        end
    end
    if mobLootOpen and not lastMoney then lastMoney = GetMoney() end
    Dbg(event, "- slots:", n, "- from a mob:", mobLootOpen)
    Update()
end

local function AddItem(link, count, mob)
    local d = Data()
    if not d.running then return end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return end
    local it = d.items[id]
    if not it then
        it = { link = link, count = 0 }
        d.items[id] = it
        table.insert(d.order, id)
    end
    it.count = it.count + count
    CountMob(d, mob)
    local m = MobType(d, mob)
    if m then m.items[id] = (m.items[id] or 0) + count end
    Price(id, link)
    Dbg("item", count .. "x", link)
    Update()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("LOOT_READY")
events:RegisterEvent("LOOT_OPENED")
events:RegisterEvent("LOOT_SLOT_CLEARED")
events:RegisterEvent("LOOT_CLOSED")
events:RegisterEvent("PLAYER_MONEY")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" then
        if Data().running then StartTicker() end
        if ns:Get("farmSession") then ShowWindow() end
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        Snapshot(event)
    elseif event == "LOOT_SLOT_CLEARED" then
        local s = slots[arg1]
        if s then
            slots[arg1] = nil
            AddItem(s.link, s.count, s.mob)
        end
    elseif event == "PLAYER_MONEY" then
        if lastMoney then   -- watching: a mob's loot window is open (or just closed)
            local now = GetMoney()
            local gain = now - lastMoney
            local d = Data()
            if gain > 0 and d.running then
                d.coin = d.coin + gain
                local m = MobType(d, coinMob)
                if m then m.coin = m.coin + gain end
                Dbg("coin", gain)
                Update()
            end
            lastMoney = now
        end
    elseif event == "LOOT_CLOSED" then
        slots, mobLootOpen = {}, false
        -- coin can arrive just after the window closes (auto-loot): keep watching for a moment
        C_Timer.After(0.5, function() if not mobLootOpen then lastMoney, coinMob = nil, nil end end)
    elseif event == "PLAYER_TARGET_CHANGED" then
        if Data().running then RememberUnit("target") end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        if Data().running then RememberUnit("mouseover") end
    end
end)
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("UPDATE_MOUSEOVER_UNIT")

---------------------------------------------------------------------------
-- Commands and option
---------------------------------------------------------------------------

-- For the Farming tab (FarmLog.lua).
ns.Farm = {
    Coins = Coins, Clock = Clock, AHName = AHName, History = History, Finish = Finish, MainZone = MainZone,
    -- the run in progress, in the same shape as a saved expedition (nil if nothing looted yet)
    Current = function()
        local d = Data()
        if d.mobs == 0 and d.coin == 0 then return nil end
        local vendor, ah, count = Totals()
        return { current = true, running = d.running, started = d.started, elapsed = d.elapsed, kills = d.mobs,
            items = count, coin = d.coin, vendor = vendor, ah = ah, priceSource = AHName(),
            zone = MainZone(d.zones), zones = d.zones, mobs = MobRanking() }
    end,
}

ns:RegisterCommand("farm", "farming tracker: /p13 farm [start | stop | finish | reset | show | hide | mobs | log | heat off | debug]", function(arg)
    arg = strtrim(arg or ""):lower()
    if arg == "mobs" then
        RefreshPrices()
        local ranking = MobRanking()
        if #ranking == 0 then return ns:Print("Farming: no mobs looted yet.") end
        ns:Print("Most profitable mobs (" .. (AHName() and "auction" or "vendor") .. " value per kill, total in brackets):")
        for i, e in ipairs(ranking) do ns:Print("  " .. i .. ". " .. MobLine(e)) end
    elseif arg == "heat" or arg == "heat off" then
        P13TweaksDB.farmHeatSel = nil
        if ns.FarmHeatChanged then ns.FarmHeatChanged() end
        Update()
        if ns.RefreshFarmLog then ns.RefreshFarmLog() end
        ns:Print("Kill heatmap hidden.")
    elseif arg == "finish" then
        if not Finish() then ns:Print("Nothing looted yet - nothing to save.") end
    elseif arg == "log" then
        local f = ns.optionsFrame
        if f then
            f:Show()
            if ns.SelectOptionsTab then ns.SelectOptionsTab("Farming") end
        end
    elseif arg == "start" then Start()
    elseif arg == "stop" then Stop()
    elseif arg == "reset" then Reset(); ns:Print("Farming session cleared.")
    elseif arg == "hide" then ns:Set("farmSession", false)
    elseif arg == "debug" then
        debugOn = not debugOn
        ns:Print("Farming tracker debug " .. (debugOn and "ON - go loot a mob." or "off."))
    else
        ns:Set("farmSession", true)
        if arg ~= "show" then
            local vendor, ah = Totals()
            local d = Data()
            ns:Print(("Farming: %s, %s. Vendor %s, Auction %s. Auction prices from: %s."):format(
                d.running and "recording" or "stopped", Clock(d.elapsed), Coins(vendor), Coins(ah),
                AHName() or "none (install TradeSkillMaster or Auctionator)"))
        end
    end
end)

ns:RegisterOption({
    key = "farmSession",
    type = "toggleButton",
    label = "Farming tracker window",
    buttonText = "Start",
    onClick = function() Start() end,
    tooltip = "A small window with Start / Stop / Reset. While it's recording, every item you loot from a mob (and the coin they drop) is counted, with two rough estimates of what it's worth, in total and per hour: selling it all to a vendor, or selling it at the auction house's average sale price (needs TradeSkillMaster or Auctionator; items with no auction price count at vendor price). The window also lists the most profitable kinds of mob, by average value per kill (/p13 farm mobs lists them all). Closing the window doesn't stop the recording. Also /p13 farm start, stop, reset.",
    default = false,
    onChange = function(v)
        if v then ShowWindow() elseif win and win:IsShown() then win:Hide() end
    end,
})

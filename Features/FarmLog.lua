-- P13Tweaks: Farming tab - a running record of your gold-farming "expeditions", to show where it's worth going back.
-- An expedition is one run of the farming tracker (FarmSession.lua), saved when you press Finish, in
-- P13TweaksDB.farmHistory: where (the zone with the most kills), when, how long, kills, coin, what it was worth
-- (vendor and auction, at the prices of the moment you finished), its best mobs and every kill's position.
-- The tab lists:
--   Best zones   every zone you farmed, by gold per hour over all your expeditions there (auction value,
--                which is the vendor price for anything without an auction price)
--   Expeditions  each one (the run in progress first), sorted by gold per hour or newest; Map shows all its
--                kills as a heatmap on the world map and minimap (FarmHeat.lua); Shift-click Delete removes one.
local ADDON_NAME, ns = ...

local ROW_H = 15
local F = function() return ns.Farm end   -- (FarmSession.lua loads first)

local page, content, contentW, sortBtn
local texts, tUsed = {}, 0
local buttons, bUsed = {}, 0

local function Text(x, y, text, font, r, g, b, width)
    tUsed = tUsed + 1
    local fs = texts[tUsed]
    if not fs then
        fs = content:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        texts[tUsed] = fs
    end
    fs:SetFontObject(font or "GameFontHighlightSmall")
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(width or (contentW - x))
    fs:SetText(text)
    fs:SetTextColor(r or 1, g or 1, b or 1)
    fs:Show()
    return fs
end

local function Button(x, y, w, label, onClick, tip)
    bUsed = bUsed + 1
    local b = buttons[bUsed]
    if not b then
        b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        b:SetHeight(18)
        b:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
        b:SetScript("OnEnter", function(self)
            if not self.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        buttons[bUsed] = b
    end
    b:SetWidth(w)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", x, y + 2)
    b:SetText(label)
    b.onClick, b.tip = onClick, tip
    b:Show()
    return b
end

local function PerHour(total, elapsed)
    if not elapsed or elapsed < 60 then return nil end
    return total / (elapsed / 3600)
end

local function Rate(total, elapsed)
    local r = PerHour(total, elapsed)
    return r and (F().Coins(r) .. "|cff999999/hr|r") or "|cff999999-/hr|r"
end

local function Delete(id)
    local hist = F().History()
    for i, e in ipairs(hist) do
        if e.id == id then table.remove(hist, i) break end
    end
    local sel = P13TweaksDB.farmHeatSel
    if sel and sel.exp == id then
        P13TweaksDB.farmHeatSel = nil
        if ns.FarmHeatChanged then ns.FarmHeatChanged() end
    end
end

local Refresh

-- One expedition: 3 lines + buttons. Returns the new y.
local function Entry(e, y)
    local Coins, Clock = F().Coins, F().Clock
    local title
    if e.current then
        title = (e.running and "|cff33ff99Now (recording)|r" or "|cffffcc00Now (stopped)|r") .. "  " .. (e.zone or "?")
    else
        title = "|cff999999#" .. e.id .. "|r  " .. (e.zone or "?")
            .. "  |cff999999" .. (e.started and date("%Y-%m-%d %H:%M", e.started) or "") .. "|r"
    end
    Text(0, y, title, "GameFontHighlight", 1, 1, 1, contentW - 140)
    local shown = ns.FarmHeatIs and ns.FarmHeatIs(e.id, nil)
    local exp = e.id   -- (nil for the run in progress)
    Button(contentW - 134, y, 66, shown and "Hide map" or "Map", function() ns.FarmHeatToggle(exp, nil) end,
        "Show every kill of this expedition as a heatmap on the world map and minimap (click again to hide).")
    if not e.current then
        Button(contentW - 66, y, 62, "Delete", function()
            if not IsShiftKeyDown() then ns:Print("Shift-click Delete to remove that expedition.") return end
            Delete(exp)
            Refresh()
        end, "Shift-click to remove this expedition from the record.")
    end
    y = y - ROW_H - 3
    Text(8, y, ("%s  |cff999999·|r  %d kills  |cff999999·|r  Auction %s %s  |cff999999·|r  Vendor %s"):format(
        Clock(e.elapsed or 0), e.kills or 0, Rate(e.ah or 0, e.elapsed), "|cff999999(" .. Coins(e.ah or 0) .. ")|r",
        Rate(e.vendor or 0, e.elapsed)))
    y = y - ROW_H
    local best = {}
    for i = 1, math.min(3, #(e.mobs or {})) do
        local m = e.mobs[i]
        best[#best + 1] = ("%s %s|cff999999/kill x%d|r"):format(m.name or "?", Coins(m.perKill or 0), m.kills or 0)
    end
    if #best > 0 then
        Text(8, y, "|cff999999Best:|r " .. table.concat(best, "|cff999999,|r  "), nil, 0.85, 0.85, 0.85)
        y = y - ROW_H
    end
    -- other zones it covered
    local zones = {}
    for z in pairs(e.zones or {}) do if z ~= e.zone then zones[#zones + 1] = z end end
    if #zones > 0 then
        table.sort(zones)
        Text(8, y, "|cff999999Also in: " .. table.concat(zones, ", ") .. "|r")
        y = y - ROW_H
    end
    return y - 8
end

Refresh = function()
    if not (content and F()) then return end
    tUsed, bUsed = 0, 0
    local Coins, Clock = F().Coins, F().Clock
    local hist = F().History()
    local cur = F().Current()
    local byRate = P13TweaksDB.farmLogSort ~= "new"
    if sortBtn then sortBtn:SetText(byRate and "Sort: gold/hour" or "Sort: newest") end

    local y = 0
    -- Best zones: total auction value / total time, over every saved expedition with its main zone there
    Text(0, y, "Best zones", "GameFontNormal", 1, 0.82, 0)
    y = y - 20
    local zones, zlist = {}, {}
    for _, e in ipairs(hist) do
        local z = e.zone or "?"
        local s = zones[z]
        if not s then s = { zone = z, ah = 0, vendor = 0, elapsed = 0, trips = 0, kills = 0 }; zones[z] = s; table.insert(zlist, s) end
        s.ah, s.vendor = s.ah + (e.ah or 0), s.vendor + (e.vendor or 0)
        s.elapsed, s.trips, s.kills = s.elapsed + (e.elapsed or 0), s.trips + 1, s.kills + (e.kills or 0)
    end
    table.sort(zlist, function(a, b) return (PerHour(a.ah, a.elapsed) or 0) > (PerHour(b.ah, b.elapsed) or 0) end)
    if #zlist == 0 then
        Text(8, y, "No expeditions yet. Start the farming tracker, farm a while, then press Finish to save it here.", nil, 0.7, 0.7, 0.7)
        y = y - ROW_H
    end
    for i, s in ipairs(zlist) do
        Text(8, y, ("%d. %s"):format(i, s.zone), nil, 1, 1, 1, 140)
        Text(150, y, ("%s  |cff999999(%d trip%s, %s, %d kills)|r"):format(
            Rate(s.ah, s.elapsed), s.trips, s.trips == 1 and "" or "s", Clock(s.elapsed), s.kills))
        y = y - ROW_H
    end

    y = y - 12
    Text(0, y, "Expeditions", "GameFontNormal", 1, 0.82, 0)
    y = y - 22
    if cur then y = Entry(cur, y) end
    local list = {}
    for _, e in ipairs(hist) do list[#list + 1] = e end
    if byRate then
        table.sort(list, function(a, b) return (PerHour(a.ah or 0, a.elapsed) or 0) > (PerHour(b.ah or 0, b.elapsed) or 0) end)
    else
        table.sort(list, function(a, b) return (a.ended or 0) > (b.ended or 0) end)
    end
    if #list == 0 and not cur then
        Text(8, y, "None yet.", nil, 0.7, 0.7, 0.7)
        y = y - ROW_H
    end
    for _, e in ipairs(list) do y = Entry(e, y) end

    for j = tUsed + 1, #texts do texts[j]:Hide() end
    for j = bUsed + 1, #buttons do buttons[j]:Hide() end
    content:SetHeight(-y + 8)
end

function ns.RefreshFarmLog()
    if page and page:IsVisible() then Refresh() end
end

ns.customPages.farmLog = function(parent, top, width)
    page = parent
    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 16, top)
    note:SetWidth(width - 150)
    note:SetJustifyH("LEFT")
    note:SetText("Values are auction prices (vendor price where there's none) when the expedition was finished, plus coin.")
    sortBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    sortBtn:SetSize(110, 20)
    sortBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -30, top + 2)
    sortBtn:SetScript("OnClick", function()
        P13TweaksDB.farmLogSort = (P13TweaksDB.farmLogSort == "new") and "rate" or "new"
        Refresh()
    end)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, top - 26)
    scroll:SetPoint("BOTTOMRIGHT", -30, 8)
    content = CreateFrame("Frame", nil, scroll)
    contentW = width - 50
    content:SetSize(contentW, 10)
    scroll:SetScrollChild(content)
    parent:HookScript("OnShow", function() C_Timer.After(0, Refresh) end)
    if parent:IsVisible() then C_Timer.After(0, Refresh) end
    -- keep the run in progress up to date while the tab is open
    local since = 0
    parent:HookScript("OnUpdate", function(_, elapsed)
        since = since + elapsed
        if since >= 3 then
            since = 0
            local d = P13TweaksDB.farmSessionData
            if d and d.running then Refresh() end
        end
    end)
end

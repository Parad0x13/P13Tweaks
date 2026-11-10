-- P13Tweaks feature: after a kill that gives experience, a number pops up below your character and
-- fades away: how many more of that same mob you'd need to kill to reach the next level.
-- It uses the experience that kill just gave (rested bonus included), so it's an estimate.
-- Below it, a running kill tally (per character, kept forever): kills of that mob (the total is in /p13 kills).
-- Kills are read from the experience message, so only kills that give experience are counted.
-- Addons can't see where your character is on screen, so it starts just below the middle of the
-- screen; /p13 killmove lets you drag it into place.
local ADDON_NAME, ns = ...

local RISE, SHOW_TIME, FADE_TIME = -25, 2.4, 1.6  -- pixels to drift (negative = down); seconds shown; seconds fading

---------------------------------------------------------------------------
-- Reading "X dies, you gain N experience." in whatever language the game uses
---------------------------------------------------------------------------

local patterns = {}

local function ToPattern(fmt)
    fmt = fmt:gsub("%%%d%$", "%%")                                -- "%1$s" -> "%s"
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")      -- escape pattern characters
    p = p:gsub("%%s", "(.-)")
    p = p:gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local function BuildPatterns()
    local formats = {}
    for k, v in pairs(_G) do
        -- "_UNNAMED" ones have no mob in them (quest/other experience), so they're not kills.
        if type(k) == "string" and type(v) == "string" and k:find("^COMBATLOG_XPGAIN_FIRSTPERSON")
            and not k:find("UNNAMED") then
            table.insert(formats, v)
        end
    end
    table.sort(formats, function(a, b) return #a > #b end)   -- most specific first
    for _, f in ipairs(formats) do table.insert(patterns, ToPattern(f)) end
end

-- Experience gained and the mob's name from a kill message, or nil if it isn't one.
local function KillXP(msg)
    for _, p in ipairs(patterns) do
        local caps = { msg:match(p) }
        if #caps > 0 then
            local xp, mob
            for _, c in ipairs(caps) do
                local n = tonumber(c)
                if n and not xp then xp = n
                elseif not n and not mob and c ~= "" then mob = c end
            end
            if xp then return xp, mob end
        end
    end
    -- Last resort (English): "X dies, you gain N experience."
    local mob, n = msg:match("^(.-) dies, you gain (%d+) experience")
    return tonumber(n), mob
end

---------------------------------------------------------------------------
-- The floating number
---------------------------------------------------------------------------

local holder = CreateFrame("Frame", "P13TweaksKillsToLevel", UIParent)
holder:SetSize(200, 40)
holder:SetFrameStrata("HIGH")
holder:Hide()

local text = holder:CreateFontString(nil, "OVERLAY")
text:SetFont(STANDARD_TEXT_FONT, 26, "OUTLINE")
text:SetPoint("CENTER")
text:SetTextColor(1.0, 0.82, 0.2)

-- Running tally, smaller, under the number (or in its place when there's no number to show).
local tally = holder:CreateFontString(nil, "OVERLAY")
tally:SetFont(STANDARD_TEXT_FONT, 15, "OUTLINE")
tally:SetPoint("TOP", text, "BOTTOM", 0, -2)
tally:SetTextColor(0.9, 0.9, 0.9)

local anim = holder:CreateAnimationGroup()
local fadeIn = anim:CreateAnimation("Alpha")
fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(0.15); fadeIn:SetOrder(1)
local rise = anim:CreateAnimation("Translation")
rise:SetOffset(0, RISE); rise:SetDuration(SHOW_TIME + FADE_TIME); rise:SetOrder(1); rise:SetSmoothing("OUT")
local fadeOut = anim:CreateAnimation("Alpha")
fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0)
fadeOut:SetStartDelay(SHOW_TIME); fadeOut:SetDuration(FADE_TIME); fadeOut:SetOrder(1)
anim:SetToFinalAlpha(true)
anim:SetScript("OnFinished", function() holder:Hide() end)

local moving = false   -- /p13 killmove: number stays visible so you can drag it

local function Place()
    holder:ClearAllPoints()
    local p = P13TweaksDB.killsToLevelPos
    if p then
        holder:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        holder:SetPoint("CENTER", UIParent, "CENTER", 0, -90)   -- roughly under your feet
    end
end

holder:SetMovable(true)
holder:SetClampedToScreen(true)
holder:RegisterForDrag("LeftButton")
holder:EnableMouse(false)   -- only clickable while moving, so it never blocks clicks
holder:SetScript("OnDragStart", function(self) if moving then self:StartMoving() end end)
holder:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    P13TweaksDB.killsToLevelPos = { point, relPoint, x, y }
end)

-- n = kills to level (or nil), tallyText = the kill tally line (or nil).
local function ShowNumber(n, tallyText)
    if moving or not (n or tallyText) then return end
    Place()
    text:SetText(n and (n .. " more") or "")
    tally:SetText(tallyText or "")
    anim:Stop()
    holder:SetAlpha(0)
    holder:Show()
    anim:Play()
end

---------------------------------------------------------------------------
-- Kill tally: P13TweaksDB.killCounts["Name-Realm"] = { total = n, mobs = { [mob] = n } }
-- (Not "killTally": that's the on/off option's saved key.)
---------------------------------------------------------------------------

local function CharTally()
    local key = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    if type(P13TweaksDB.killCounts) ~= "table" then P13TweaksDB.killCounts = {} end
    local t = P13TweaksDB.killCounts[key]
    if not t then
        t = { total = 0, mobs = {} }
        P13TweaksDB.killCounts[key] = t
    end
    return t
end

-- Counts one kill (always, even while the display is off) and returns the line to show.
local function CountKill(mob)
    local t = CharTally()
    t.total = t.total + 1
    if mob then t.mobs[mob] = (t.mobs[mob] or 0) + 1 end
    if not mob then return nil end   -- the popup only shows the count for that mob
    return mob .. " |cffffd200x" .. t.mobs[mob] .. "|r"
end

---------------------------------------------------------------------------
-- Kill counts window: every mob this character has killed, most first, each with a
-- button to clear it. Opened from the "View" button next to the option, or /p13 kills.
---------------------------------------------------------------------------

local ROW_H = 20
local win, content, totalText, emptyText
local rows = {}
local RefreshWindow

-- Removes one mob's kills (and takes them off the total), or everything when mob is nil.
local function ClearKills(mob)
    local t = CharTally()
    if mob then
        t.total = math.max(0, t.total - (t.mobs[mob] or 0))
        t.mobs[mob] = nil
    else
        t.total, t.mobs = 0, {}
    end
    if RefreshWindow then RefreshWindow() end
end

StaticPopupDialogs["P13TWEAKS_CLEAR_ALL_KILLS"] = {
    text = "Clear every kill count for this character?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function() ClearKills(nil) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Frame", nil, content)
    r:SetSize(270, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)

    r.clear = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.clear:SetSize(50, 18)
    r.clear:SetPoint("RIGHT", 0, 0)
    r.clear:SetText("Clear")
    r.clear:SetScript("OnClick", function(self) ClearKills(self:GetParent().mob) end)

    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.count:SetPoint("RIGHT", r.clear, "LEFT", -8, 0)
    r.count:SetJustifyH("RIGHT")
    r.count:SetWidth(50)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetPoint("LEFT", 4, 0)
    r.name:SetPoint("RIGHT", r.count, "LEFT", -6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    rows[i] = r
    return r
end

local function BuildWindow()
    win = CreateFrame("Frame", "P13TweaksKillCounts", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(320, 420)
    win:SetPoint("CENTER", 200, 0)
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
    title:SetText("Kill counts - " .. (UnitName("player") or "?"))

    totalText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    totalText:SetPoint("TOPLEFT", 14, -36)

    local clearAll = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    clearAll:SetSize(80, 20)
    clearAll:SetPoint("TOPRIGHT", -12, -32)
    clearAll:SetText("Clear all")
    clearAll:SetScript("OnClick", function() StaticPopup_Show("P13TWEAKS_CLEAR_ALL_KILLS") end)

    local scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -60)
    scroll:SetPoint("BOTTOMRIGHT", -32, 10)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(270, 1)
    scroll:SetScrollChild(content)

    emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOPLEFT", 4, -4)
    emptyText:SetText("No kills counted yet.")

    win:SetScript("OnShow", function() RefreshWindow() end)
end

RefreshWindow = function()
    if not (win and win:IsShown()) then return end
    local t = CharTally()
    totalText:SetText(("Total: %d"):format(t.total))

    local list = {}
    for mob, n in pairs(t.mobs) do table.insert(list, { mob, n }) end
    table.sort(list, function(a, b)
        if a[2] ~= b[2] then return a[2] > b[2] end
        return a[1] < b[1]
    end)

    for i, e in ipairs(list) do
        local r = Row(i)
        r.mob = e[1]
        r.name:SetText(e[1])
        r.count:SetText(e[2])
        r:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide(); rows[i].mob = nil end
    content:SetHeight(math.max(1, #list * ROW_H))
    emptyText:SetShown(#list == 0)
end

local function ToggleWindow()
    if not win then BuildWindow() end
    if win:IsShown() then win:Hide() else win:Show(); win:Raise() end
end

local function AtMaxLevel()
    if IsXPUserDisabled and IsXPUserDisabled() then return true end
    local maxLevel = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion())
        or (GetMaxPlayerLevel and GetMaxPlayerLevel())
    return maxLevel and UnitLevel("player") >= maxLevel
end

local function OnKillXP(xp, mob)
    if not (xp and xp > 0) then return end
    -- Guarded: a problem with the tally must never stop the kills-to-level number.
    local ok, line = pcall(CountKill, mob)
    if ok then RefreshWindow() end
    if not ok or not ns:Get("killTally") then line = nil end
    local wantLeft = ns:Get("killsToLevel") and not AtMaxLevel()
    -- Wait a moment so the game has added this kill's experience to your bar.
    C_Timer.After(0.1, function()
        local n
        if wantLeft then
            local left = UnitXPMax("player") - UnitXP("player")
            if left > 0 then n = math.ceil(left / xp) end
        end
        ShowNumber(n, line)
    end)
end

ns:RegisterOption({
    key = "killsToLevel",
    type = "toggle",
    label = "Show kills-to-level below my character",
    tooltip = "After you kill a mob that gives experience, a number pops up below your character showing how many more of that mob you'd need to kill to level up. Type /p13 killmove to drag it into place.",
    default = true,
})

ns:RegisterOption({
    key = "killTally",
    type = "toggleButton",
    label = "Show running kill count",
    buttonText = "View",
    buttonWidth = 60,
    onClick = function() ToggleWindow() end,
    tooltip = "Under the kills-to-level number: how many of that enemy this character has killed. Counted from the experience message, so kills that give no experience (grey mobs) aren't included. The count keeps going even while this is off.\n\nView opens the full list, where you can clear any mob's count (or all of them).",
    default = true,
})

ns:RegisterCommand("killtest", "show a sample kills-to-level number", function()
    ShowNumber(math.random(5, 40), ns:Get("killTally") and "Kobold Vermin |cffffd200x12|r" or nil)
end)

ns:RegisterCommand("kills", "open the kill counts window (clear any mob's count there)", function()
    ToggleWindow()
end)

ns:RegisterCommand("killmove", "show the kills-to-level number so you can drag it (again to finish)", function()
    moving = not moving
    anim:Stop()
    holder:EnableMouse(moving)
    if moving then
        Place()
        text:SetText("88 more")
        tally:SetText("Kobold Vermin |cffffd200x12|r")
        holder:SetAlpha(1)
        holder:Show()
        ns:Print("Drag the number to where you want it (e.g. under your character), then type /p13 killmove again.")
    else
        holder:Hide()
        ns:Print("Kills-to-level position saved.")
    end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
events:SetScript("OnEvent", function(self, event, msg)
    if event == "PLAYER_LOGIN" then
        BuildPatterns()
    elseif msg then
        OnKillXP(KillXP(msg))   -- always: the tally keeps counting even if the display is off
    end
end)

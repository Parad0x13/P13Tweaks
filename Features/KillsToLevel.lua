-- P13Tweaks feature: after a kill that gives experience, a number pops up below your character and
-- fades away: how many more of that same mob you'd need to kill to reach the next level.
-- It uses the experience that kill just gave (rested bonus included), so it's an estimate.
-- Addons can't see where your character is on screen, so it starts just below the middle of the
-- screen; /p13 killmove lets you drag it into place.
local ADDON_NAME, ns = ...

local RISE, SHOW_TIME, FADE_TIME = -25, 1.2, 0.8  -- pixels to drift (negative = down); seconds shown; seconds fading

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

-- Experience gained from a kill message, or nil if it isn't one.
local function KillXP(msg)
    for _, p in ipairs(patterns) do
        local caps = { msg:match(p) }
        if #caps > 0 then
            for _, c in ipairs(caps) do
                local n = tonumber(c)
                if n then return n end
            end
        end
    end
    -- Last resort (English): "X dies, you gain N experience."
    return tonumber(msg:match("dies, you gain (%d+) experience"))
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

local function ShowNumber(n)
    if moving then return end
    Place()
    text:SetText(n .. " more")
    anim:Stop()
    holder:SetAlpha(0)
    holder:Show()
    anim:Play()
end

local function AtMaxLevel()
    if IsXPUserDisabled and IsXPUserDisabled() then return true end
    local maxLevel = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion())
        or (GetMaxPlayerLevel and GetMaxPlayerLevel())
    return maxLevel and UnitLevel("player") >= maxLevel
end

local function OnKillXP(xp)
    if not (xp and xp > 0) or AtMaxLevel() then return end
    -- Wait a moment so the game has added this kill's experience to your bar.
    C_Timer.After(0.1, function()
        local left = UnitXPMax("player") - UnitXP("player")
        if left <= 0 then return end
        ShowNumber(math.ceil(left / xp))
    end)
end

ns:RegisterOption({
    key = "killsToLevel",
    type = "toggle",
    label = "Show kills-to-level below my character",
    tooltip = "After you kill a mob that gives experience, a number pops up below your character showing how many more of that mob you'd need to kill to level up. Type /p13 killmove to drag it into place.",
    default = true,
})

ns:RegisterCommand("killtest", "show a sample kills-to-level number", function()
    ShowNumber(math.random(5, 40))
end)

ns:RegisterCommand("killmove", "show the kills-to-level number so you can drag it (again to finish)", function()
    moving = not moving
    anim:Stop()
    holder:EnableMouse(moving)
    if moving then
        Place()
        text:SetText("88 more")
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
    elseif ns:Get("killsToLevel") and msg then
        OnKillXP(KillXP(msg))
    end
end)

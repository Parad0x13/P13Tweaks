-- P13Tweaks feature: beep when a hostile target you're approaching comes within ~30 yards.
-- The game doesn't give addons a mob's exact distance, only "is it in range of X?".
-- We ask using items with a 30 yd range (you don't need to own them), and fall back to
-- the built-in 28 yd "follow" range check if the item check isn't available.
local ADDON_NAME, ns = ...

local RANGE_ITEMS = { 835, 7734 }   -- Large Rope Net, Six Demon Bag: both 30 yd on enemies
local CHECK_EVERY = 0.1             -- seconds between range checks
local COOLDOWN    = 2               -- don't beep again within this many seconds
local SOUND       = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959   -- loud raid-warning horn

local IsItemInRange = (C_Item and C_Item.IsItemInRange) or _G.IsItemInRange

-- Returns true = within ~30 yd, false = farther, nil = can't tell right now,
-- plus a short description of which check answered (for /p13 range).
local function InRange()
    if IsItemInRange then
        for _, id in ipairs(RANGE_ITEMS) do
            local ok, r = pcall(IsItemInRange, id, "target")
            if ok and r ~= nil then return r and true or false, "item " .. id end
        end
    end
    if CheckInteractDistance then
        local ok, r = pcall(CheckInteractDistance, "target", 4)  -- 4 = follow range, ~28 yd
        if ok and r ~= nil then return r and true or false, "follow range (28 yd)" end
    end
    return nil, "no range check worked"
end

local function Beep()
    PlaySound(SOUND, "Master")
end

local function ValidTarget()
    return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")
end

-- Range dot over your own character. It pops in only when your target crosses the 30 yd line
-- (green = just came within 30 yd, red = just went beyond), then fades away.
-- Addons can't read where your character is on screen, but the camera keeps you near the
-- middle, so the dot sits just above centre. Type /p13 dot to show it and drag it into place.
local DOT_COLORS = { [true] = { 0.2, 1.0, 0.2 }, [false] = { 1.0, 0.2, 0.2 } }
local DOT_IN, DOT_HOLD, DOT_OUT = 0.2, 1.0, 0.5   -- seconds: pop in, stay, fade out

-- The marker is a crosshair: four bars around a small gap, each with a dark outline.
local ARM, THICK, GAP, OUTLINE = 9, 2, 4, 1   -- pixels: bar length, bar thickness, centre gap, outline
local SIZE = 2 * (ARM + GAP)

local dot = CreateFrame("Frame", "P13TweaksRangeDot", UIParent)
dot:SetSize(SIZE, SIZE)
dot:SetFrameStrata("HIGH")
dot:Hide()

local bars = {}
-- dx, dy = which side of the centre the bar sits on
for _, d in ipairs({ { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }) do
    local w, h = THICK, ARM
    if d[1] ~= 0 then w, h = ARM, THICK end
    local off = GAP + ARM / 2
    local outline = dot:CreateTexture(nil, "BACKGROUND")
    outline:SetSize(w + 2 * OUTLINE, h + 2 * OUTLINE)
    outline:SetPoint("CENTER", dot, "CENTER", d[1] * off, d[2] * off)
    outline:SetColorTexture(0, 0, 0, 0.8)
    local bar = dot:CreateTexture(nil, "OVERLAY")
    bar:SetSize(w, h)
    bar:SetPoint("CENTER", dot, "CENTER", d[1] * off, d[2] * off)
    bar:SetColorTexture(1, 1, 1)
    table.insert(bars, bar)
end

local function SetDotColor(r, g, b)
    for _, bar in ipairs(bars) do bar:SetVertexColor(r, g, b) end
end

-- Pop in (grow + fade in), hold, fade out.
local anim = dot:CreateAnimationGroup()
local grow = anim:CreateAnimation("Scale")
if grow.SetScaleFrom then
    grow:SetScaleFrom(0.2, 0.2); grow:SetScaleTo(1, 1)
elseif grow.SetFromScale then
    grow:SetFromScale(0.2, 0.2); grow:SetToScale(1, 1)
end
grow:SetDuration(DOT_IN); grow:SetOrder(1); grow:SetSmoothing("OUT")
local fadeIn = anim:CreateAnimation("Alpha")
fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1)
fadeIn:SetDuration(DOT_IN); fadeIn:SetOrder(1)
local fadeOut = anim:CreateAnimation("Alpha")
fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0)
fadeOut:SetStartDelay(DOT_HOLD); fadeOut:SetDuration(DOT_OUT); fadeOut:SetOrder(2)
anim:SetToFinalAlpha(true)
anim:SetScript("OnFinished", function() dot:Hide() end)

local moving = false   -- /p13 dot: dot stays visible so you can drag it

local function FlashDot(r)
    if moving or not ns:Get("rangeDot") then return end
    local c = DOT_COLORS[r]
    SetDotColor(c[1], c[2], c[3])
    anim:Stop()
    dot:SetAlpha(0)
    dot:Show()
    anim:Play()
end

local function PlaceDot()
    dot:ClearAllPoints()
    local p = P13TweaksDB.rangeDotPos
    if p then dot:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else dot:SetPoint("CENTER", UIParent, "CENTER", 0, 70) end
end
dot:SetMovable(true)
dot:SetClampedToScreen(true)
dot:RegisterForDrag("LeftButton")
dot:EnableMouse(false)                 -- only clickable in move mode, so it never blocks clicks
dot:SetScript("OnDragStart", function(self) if moving then self:StartMoving() end end)
dot:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    P13TweaksDB.rangeDotPos = { point, relPoint, x, y }
end)

ns:RegisterCommand("dot", "show the range crosshair so you can drag it over your head (again to finish); /p13 dot test to flash it", function(arg)
    if arg == "test" then
        local wasOn = ns:Get("rangeDot")
        if moving then ns:Print("Finish moving first (/p13 dot)."); return end
        P13TweaksDB.rangeDot = true
        FlashDot(true)
        P13TweaksDB.rangeDot = wasOn
        C_Timer.After(2, function() local w = P13TweaksDB.rangeDot; P13TweaksDB.rangeDot = true; FlashDot(false); P13TweaksDB.rangeDot = w end)
        ns:Print("Flashing the crosshair green, then red in 2 seconds." .. (wasOn and "" or " (The option is OFF in /p13.)"))
        return
    end
    moving = not moving
    anim:Stop()
    dot:EnableMouse(moving)
    if moving then
        SetDotColor(1, 1, 1)
        dot:SetAlpha(1)
        dot:Show()
        ns:Print("Drag the white crosshair over your character's head, then type /p13 dot again.")
    else
        dot:Hide()
        ns:Print("Crosshair position saved.")
    end
end)

local armed, lastBeep, since = false, 0, 0
local lastRange                        -- target's last known side of the 30 yd line
local frame = CreateFrame("Frame")

frame:SetScript("OnUpdate", function(self, dt)
    since = since + dt
    if since < CHECK_EVERY then return end
    since = 0
    if not ValidTarget() then armed = false; lastRange = nil; return end

    local r = InRange()
    if r ~= nil then
        if lastRange ~= nil and r ~= lastRange then FlashDot(r) end   -- crossed the line
        lastRange = r
    end
    if not ns:Get("rangeBeep") then return end
    if r == false then
        armed = true                       -- target is far away: beep once it gets close
    elseif r == true and armed then
        armed = false
        if GetTime() - lastBeep >= COOLDOWN then
            lastBeep = GetTime()
            Beep()
        end
    end
end)

local function Update()
    armed, lastRange = false, nil
    if ns:Get("rangeBeep") or ns:Get("rangeDot") then frame:Show() else frame:Hide() end
    if not ns:Get("rangeDot") and not moving then anim:Stop(); dot:Hide() end
end

ns:RegisterOption({
    key = "rangeBeep",
    type = "toggle",
    label = "Beep when target is within 30 yards",
    tooltip = "If you target an enemy that's more than 30 yards away, a beep plays when you get within 30 yards of it. Plays again if it leaves range and comes back.",
    default = true,
    onChange = Update,
})

ns:RegisterOption({
    key = "rangeDot",
    type = "toggle",
    label = "Range crosshair over my character",
    tooltip = "A crosshair pops up above your character for a moment when your target crosses 30 yards: green when it comes within 30 yards, red when it goes beyond. Type /p13 dot to drag it into place over your head.",
    default = true,
    onChange = Update,
})

ns:RegisterCommand("range", "play the beep and show whether your target is within 30 yards", function()
    Beep()
    ns:Print("Played the beep (raid warning sound, Master channel).")
    if not UnitExists("target") then ns:Print("No target."); return end
    local r, how = InRange()
    ns:Print("Target is " .. (r == true and "within 30 yd" or r == false and "farther than 30 yd" or "unknown range")
        .. " - " .. how .. ". Enemy: " .. tostring(UnitCanAttack("player", "target") and true or false)
        .. ", option on: " .. tostring(ns:Get("rangeBeep") and true or false))
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        -- Range checks by item ID need the item's info loaded first.
        for _, id in ipairs(RANGE_ITEMS) do
            if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id)
            elseif GetItemInfo then GetItemInfo(id) end
        end
        P13TweaksDB.rangeRing, P13TweaksDB.rangeRingPos = nil, nil  -- removed option
        PlaceDot()
        Update()
    else
        armed, lastRange = false, nil   -- new target: start fresh (no beep/dot if it's already close)
    end
end)

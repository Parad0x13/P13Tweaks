-- P13Tweaks feature: beep when a hostile target you're approaching comes within X yards
-- (X is typed into the options window, default 30).
-- The game doesn't give addons a mob's exact distance, only "is it in range of this item?".
-- So we ask with items of known range (you don't need to own them). That only works at
-- the distances in RANGE_ITEMS: a typed X is snapped to the nearest one. 28 yd uses the
-- built-in "follow" range check instead of an item.
local ADDON_NAME, ns = ...

-- yards -> enemy-range items (list from LibRangeCheck). Not every item may exist on every
-- client; if none at the chosen distance answer, the nearest distance that does is used
-- and /p13 range says so.
local RANGE_ITEMS = {
    [5]   = { 8149, 136605, 63427 },  -- Voodoo Charm, Solendra's Compassion, Worgsaw
    [7]   = { 61323 },                -- Ruby Seeds
    [8]   = { 34368, 33278 },         -- Attuned Crystal Cores, Burning Torch
    [10]  = { 32321 },                -- Sparrowhawk Net
    [15]  = { 33069 },                -- Sturdy Rope
    [20]  = { 10645 },                -- Gnomish Death Ray
    [25]  = { 24268, 41509 },         -- Netherweave Net, Frostweave Net
    [28]  = "follow",                 -- CheckInteractDistance index 4
    [30]  = { 835, 7734, 34191 },     -- Large Rope Net, Six Demon Bag, Handful of Snowflakes
    [35]  = { 18904 },                -- Zorbin's Ultra-Shrinker
    [40]  = { 28767 },                -- The Decapitator
    [45]  = { 23836 },                -- Goblin Rocket Launcher
    [50]  = { 116139 },               -- Haunting Memento
    [55]  = { 74637 },                -- Kiryn's Poison Vial
    [60]  = { 32825, 37887 },         -- Soul Cannon, Seeds of Nature's Wrath
    [70]  = { 41265 },                -- Eyesore Blaster
    [80]  = { 35278 },                -- Reinforced Net
    [90]  = { 133925 },               -- Fel Lash
    [100] = { 33119 },                -- Malister's Frost Wand
}
local DISTANCES = {}
for yd in pairs(RANGE_ITEMS) do table.insert(DISTANCES, yd) end
table.sort(DISTANCES)

local DEFAULT_YARDS = 30
local CHECK_EVERY = 0.1             -- seconds between range checks
local COOLDOWN    = 2               -- don't beep again within this many seconds
local SOUND       = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959   -- loud raid-warning horn

local IsItemInRange = (C_Item and C_Item.IsItemInRange) or _G.IsItemInRange

-- Nearest distance we can check to what was typed (ties go to the shorter one).
local function Snap(n)
    local best
    for _, yd in ipairs(DISTANCES) do
        if not best or math.abs(yd - n) < math.abs(best - n) then best = yd end
    end
    return best
end

local function Yards() return ns:Get("rangeBeepYards") or DEFAULT_YARDS end

-- Distances to try, the chosen one first, then the rest nearest-first. Rebuilt on change.
local tryOrder = {}
local function BuildTryOrder()
    local want = Yards()
    wipe(tryOrder)
    for _, yd in ipairs(DISTANCES) do table.insert(tryOrder, yd) end
    table.sort(tryOrder, function(a, b)
        local da, db = math.abs(a - want), math.abs(b - want)
        if da ~= db then return da < db end
        return a < b
    end)
end

local function CheckAt(yd, unit)
    unit = unit or "target"
    local how = RANGE_ITEMS[yd]
    if how == "follow" then
        if CheckInteractDistance then
            local ok, r = pcall(CheckInteractDistance, unit, 4)
            if ok and r ~= nil and not (issecretvalue and issecretvalue(r)) then
                return r and true or false, "follow range check"
            end
        end
    elseif IsItemInRange then
        for _, id in ipairs(how) do
            local ok, r = pcall(IsItemInRange, id, unit)
            if ok and r ~= nil and not (issecretvalue and issecretvalue(r)) then
                return r and true or false, "item " .. id
            end
        end
    end
    return nil
end

-- For other features (AggroRange.lua): roughly how far away `unit` is, as a band.
-- Returns lo, hi: farther than lo yards and within hi yards. lo = 0 when it's within the
-- closest checkable distance; hi = nil when it's beyond maxYd (or no check answered).
function ns.UnitDistanceBand(unit, maxYd)
    local lo, any = 0, false
    for _, yd in ipairs(DISTANCES) do
        if maxYd and yd > maxYd then break end
        local r = CheckAt(yd, unit)
        if r == true then return lo, yd end
        if r == false then lo, any = yd, true end
    end
    if any then return lo, nil end
end

-- Returns true = within range, false = farther, nil = can't tell right now,
-- plus which check answered and the distance it really checked (for /p13 range).
local function InRange()
    if #tryOrder == 0 then BuildTryOrder() end
    for _, yd in ipairs(tryOrder) do
        local r, how = CheckAt(yd)
        if r ~= nil then return r, how, yd end
    end
    return nil, "no range check worked"
end

local function Beep()
    PlaySound(SOUND, "Master")
end

local function ValidTarget()
    return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")
end

-- Range dot over your own character. It pops in only when your target crosses the beep
-- range line (green = just came within range, red = just went beyond), then fades away.
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
local lastRange                        -- target's last known side of the beep range line
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
    BuildTryOrder()
    if ns:Get("rangeBeep") or ns:Get("rangeDot") then frame:Show() else frame:Hide() end
    if not ns:Get("rangeDot") and not moving then anim:Stop(); dot:Hide() end
end

ns:RegisterOption({
    key = "rangeBeep",
    type = "toggleNumber",
    label = "Beep when target is within range",
    before = "Beep when target is within",
    after = "yards",
    numberKey = "rangeBeepYards",
    numberDefault = DEFAULT_YARDS,
    snap = function(n)
        local yd = Snap(n)
        if yd ~= n then
            ns:Print(("The game can only check certain distances - using %d yards (nearest to %d)."):format(yd, n))
        end
        return yd
    end,
    tooltip = "Type a distance in the box. If you target an enemy that's farther away than that, a beep plays when you get within that distance of it. Plays again if it leaves range and comes back.\n\nThe game only lets addons check certain distances (5, 7, 8, 10, 15, 20, 25, 28, 30, 35, 40, 45, 50, 55, 60, 70, 80, 90, 100), so what you type is rounded to the nearest one.",
    default = true,
    onChange = Update,
})

ns:RegisterOption({
    key = "rangeDot",
    type = "toggle",
    label = "Range crosshair over my character",
    tooltip = "A crosshair pops up above your character for a moment when your target crosses your beep range: green when it comes within range, red when it goes beyond. Type /p13 dot to drag it into place over your head.",
    default = true,
    onChange = Update,
})

ns:RegisterCommand("range", "play the beep and show whether your target is within your beep range", function()
    Beep()
    ns:Print("Played the beep (raid warning sound, Master channel).")
    if not UnitExists("target") then ns:Print("No target."); return end
    local r, how, yd = InRange()
    local want = Yards()
    local dist = yd and (yd .. " yd" .. (yd ~= want and (" - |cffffd200" .. want .. " yd didn't work on this client|r") or "")) or (want .. " yd")
    ns:Print("Target is " .. (r == true and "within " or r == false and "farther than " or "unknown range vs ") .. dist
        .. " - " .. how .. ". Enemy: " .. tostring(UnitCanAttack("player", "target") and true or false)
        .. ", option on: " .. tostring(ns:Get("rangeBeep") and true or false))
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        -- Range checks by item ID need the item's info loaded first.
        for _, how in pairs(RANGE_ITEMS) do
            if type(how) == "table" then
                for _, id in ipairs(how) do
                    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id)
                    elseif GetItemInfo then GetItemInfo(id) end
                end
            end
        end
        P13TweaksDB.rangeRing, P13TweaksDB.rangeRingPos = nil, nil  -- removed option
        PlaceDot()
        Update()
    else
        armed, lastRange = false, nil   -- new target: start fresh (no beep/dot if it's already close)
    end
end)

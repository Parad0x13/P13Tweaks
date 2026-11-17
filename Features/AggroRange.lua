-- P13Tweaks feature: aggro range of your target.
-- A small gauge shows how close you are to the hostile mob you've targeted, against its
-- estimated aggro radius: red zone = it will attack you, yellow = getting close, green = safe.
-- A chime plays as you near the edge, and a double chime once you're inside.
--
-- Estimates only. The game doesn't tell addons a mob's aggro radius, so it uses the Classic
-- rule of thumb: about 20 yards at your level, 1 yard less per level you're above the mob and
-- 1 more per level below (5 to 45 yards). Your distance comes from the game's range checks,
-- which only answer at set distances (see RangeBeep.lua), so it's a band, e.g. "20-25 yd".
local ADDON_NAME, ns = ...

local BASE_RADIUS, MIN_RADIUS, MAX_RADIUS = 20, 5, 45
local WARN = 5               -- yards outside the aggro edge that count as "close"
local CHECK_EVERY = 0.2      -- seconds between checks
local COOLDOWN = 2           -- seconds between chimes
local CHIME = (SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3) or 12867

local BAR_W, BAR_H = 220, 10
local COLORS = {
    SAFE   = { 0.25, 0.9, 0.35 },
    CLOSE  = { 1.0, 0.82, 0.1 },
    EDGE   = { 1.0, 0.5, 0.1 },
    INSIDE = { 1.0, 0.2, 0.2 },
    UNKNOWN = { 0.6, 0.6, 0.6 },
}
local STATUS = {
    SAFE   = "Safe - outside its aggro range",
    CLOSE  = "Careful - near the edge of its aggro range",
    EDGE   = "On the edge - one more step may pull it",
    INSIDE = "Inside its aggro range!",
    UNKNOWN = "Can't measure the distance right now",
}

---------------------------------------------------------------------------
-- Estimates
---------------------------------------------------------------------------

local function AggroRadius()
    local mob, me = UnitLevel("target"), UnitLevel("player")
    if not (mob and me) then return end
    if mob < 0 then return MAX_RADIUS end   -- ?? level (boss / far above you)
    return math.max(MIN_RADIUS, math.min(MAX_RADIUS, BASE_RADIUS + (mob - me)))
end

-- Hostile mobs that aren't already fighting: the ones an aggro range matters for.
local function ShouldShow()
    if not ns:Get("aggroRange") then return false end
    if not UnitExists("target") or UnitIsDead("target") or UnitIsPlayer("target") then return false end
    if not UnitCanAttack("player", "target") then return false end
    local reaction = UnitReaction("target", "player")
    if not reaction or reaction > 3 then return false end   -- neutral (yellow) mobs never aggro
    if UnitAffectingCombat("target") then return false end
    return true
end

-- SAFE / CLOSE / EDGE / INSIDE / UNKNOWN, plus the distance band.
local function Measure(radius)
    if not ns.UnitDistanceBand then return "UNKNOWN" end
    local lo, hi = ns.UnitDistanceBand("target", radius + WARN + 20)
    if not lo then return "UNKNOWN" end
    local state
    if hi and hi <= radius then state = "INSIDE"
    elseif lo >= radius + WARN then state = "SAFE"
    elseif lo >= radius then state = "CLOSE"
    else state = "EDGE" end   -- the band straddles the edge
    return state, lo, hi
end

---------------------------------------------------------------------------
-- Gauge
---------------------------------------------------------------------------

local gauge = CreateFrame("Frame", "P13TweaksAggroGauge", UIParent)
gauge:SetSize(BAR_W + 20, 62)
gauge:SetFrameStrata("MEDIUM")
gauge:SetClampedToScreen(true)
gauge:SetMovable(true)
gauge:EnableMouse(true)
gauge:RegisterForDrag("LeftButton")
gauge:Hide()

local bg = gauge:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0.05, 0.05, 0.07, 0.75)

local nameText = gauge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
nameText:SetPoint("TOPLEFT", 10, -7)
nameText:SetPoint("RIGHT", gauge, "CENTER", 20, 0)
nameText:SetJustifyH("LEFT")
nameText:SetWordWrap(false)

local radiusText = gauge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
radiusText:SetPoint("TOPRIGHT", -10, -7)
radiusText:SetJustifyH("RIGHT")

local bar = CreateFrame("Frame", nil, gauge)
bar:SetSize(BAR_W, BAR_H)
bar:SetPoint("TOP", 0, -24)
local barBack = bar:CreateTexture(nil, "BACKGROUND")
barBack:SetAllPoints()
barBack:SetColorTexture(0, 0, 0, 0.8)

local function Zone(layer) return bar:CreateTexture(nil, layer or "BORDER") end
local redZone, yellowZone, greenZone = Zone(), Zone(), Zone()
redZone:SetColorTexture(0.85, 0.15, 0.15, 0.85)
yellowZone:SetColorTexture(0.95, 0.75, 0.1, 0.85)
greenZone:SetColorTexture(0.2, 0.7, 0.3, 0.85)

-- where you are: a bright band (the range checks only give a band, not an exact spot)
local you = Zone("ARTWORK")
you:SetColorTexture(1, 1, 1, 0.55)
local youLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
youLabel:SetPoint("BOTTOM", you, "TOP", 0, 1)
youLabel:SetText("you")

local statusText = gauge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
statusText:SetPoint("BOTTOM", 0, 7)

-- Stretch `tex` along the bar from fromYd to toYd; `pad` makes it stick out above and below.
local function Span(tex, fromYd, toYd, scale, pad)
    fromYd, toYd = math.max(0, fromYd), math.min(scale, toYd)
    if toYd <= fromYd then tex:Hide(); return end
    pad = pad or 0
    local x = BAR_W * fromYd / scale
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", bar, "TOPLEFT", x, pad)
    tex:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x, -pad)
    tex:SetWidth(math.max(2, BAR_W * (toYd - fromYd) / scale))
    tex:Show()
end

local function Draw(radius, state, lo, hi)
    local scale = math.max(40, radius + WARN + 15)   -- yards across the whole bar
    Span(redZone, 0, radius, scale)
    Span(yellowZone, radius, radius + WARN, scale)
    Span(greenZone, radius + WARN, scale, scale)

    if lo then
        local from, to = lo, hi or scale
        Span(you, from, math.max(to, from + 1), scale, 3)
        youLabel:Show()
    else
        you:Hide(); youLabel:Hide()
    end

    nameText:SetText(UnitName("target") or "")
    local c = COLORS[state]
    radiusText:SetText(("aggro ~%d yd"):format(radius))
    local dist = lo and (hi and ("%d-%d yd"):format(lo, hi) or ("%d+ yd"):format(lo)) or "?"
    statusText:SetText(STATUS[state] .. "  (" .. dist .. ")")
    statusText:SetTextColor(c[1], c[2], c[3])
end

local function PlaceGauge()
    gauge:ClearAllPoints()
    local p = P13TweaksDB.aggroRangePos
    if p then gauge:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else gauge:SetPoint("CENTER", UIParent, "CENTER", 0, -170) end
end
gauge:SetScript("OnDragStart", gauge.StartMoving)
gauge:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    P13TweaksDB.aggroRangePos = { point, relPoint, x, y }
end)
gauge:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Aggro range (estimate)", 1, 1, 1)
    GameTooltip:AddLine("Red: the mob will attack you. Yellow: within " .. WARN .. " yards of that. White band: where you are.", nil, nil, nil, true)
    GameTooltip:AddLine("Drag to move.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
gauge:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------------------
-- Chimes
---------------------------------------------------------------------------

local armedClose, armedInside, lastChime = false, false, 0
local firstReading = true

local function Chime(times)
    if not ns:Get("aggroBeep") or GetTime() - lastChime < COOLDOWN then return end
    lastChime = GetTime()
    PlaySound(CHIME, "Master")
    if times > 1 then C_Timer.After(0.18, function() PlaySound(CHIME, "Master") end) end
end

local function OnState(state)
    if state == "UNKNOWN" then return end
    if firstReading then
        -- new target: no chime for where you already are, only for getting closer
        firstReading = false
        armedClose = state == "SAFE"
        armedInside = state ~= "INSIDE"
        return
    end
    if state == "SAFE" then
        armedClose, armedInside = true, true
    elseif state == "INSIDE" then
        if armedInside then armedInside, armedClose = false, false; Chime(2) end
    elseif armedClose then   -- CLOSE or EDGE
        armedClose = false
        Chime(1)
    end
end

---------------------------------------------------------------------------
-- Update loop, options
---------------------------------------------------------------------------

local since = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, dt)
    since = since + dt
    if since < CHECK_EVERY then return end
    since = 0
    local radius = ShouldShow() and AggroRadius()
    if not radius then gauge:Hide(); return end
    local state, lo, hi = Measure(radius)
    OnState(state)
    Draw(radius, state, lo, hi)
    gauge:Show()
end)

local function Update()
    firstReading = true
    if ns:Get("aggroRange") then ticker:Show() else ticker:Hide(); gauge:Hide() end
end

ns:RegisterOption({
    key = "aggroRange",
    type = "toggle",
    label = "Aggro range gauge for my target",
    tooltip = "When you target a hostile mob that isn't fighting yet, a small gauge shows its estimated aggro range (red), a " .. WARN .. "-yard warning zone (yellow) and where you are (white band). Drag it to move it.\n\nEstimates: the radius uses the Classic rule (about 20 yards at your level, 1 yard less per level you're above the mob, 1 more per level below, 5-45 yards), and addons can only measure distance in steps, so your spot is a band.",
    default = true,
    onChange = Update,
})

ns:RegisterOption({
    key = "aggroBeep",
    type = "toggle",
    label = "Chime when I near or enter its aggro range",
    tooltip = "With the aggro range gauge on: one chime when you get within " .. WARN .. " yards of your target's aggro range, two when you step inside it. It re-arms once you back off to safe.",
    default = true,
})

ns:RegisterCommand("aggro", "show your target's estimated aggro range and your distance", function()
    if not UnitExists("target") then ns:Print("No target."); return end
    local radius = AggroRadius()
    if not radius then ns:Print("Can't read levels."); return end
    local state, lo, hi = Measure(radius)
    ns:Print(("%s: aggro ~%d yd. You: %s. %s%s"):format(UnitName("target") or "?", radius,
        lo and (hi and ("%d-%d yd"):format(lo, hi) or ("%d+ yd"):format(lo)) or "unknown",
        STATUS[state], ShouldShow() and "" or " |cffffd200(gauge hidden: not a hostile mob out of combat, or option off)|r"))
end)

ticker:RegisterEvent("PLAYER_LOGIN")
ticker:RegisterEvent("PLAYER_TARGET_CHANGED")
ticker:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        PlaceGauge()
        Update()
    else
        firstReading = true
    end
end)

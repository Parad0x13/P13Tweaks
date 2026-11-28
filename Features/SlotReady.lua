-- P13Tweaks feature: pick action bar squares; each one dings when whatever is on it comes off cooldown.
-- The squares are picked by clicking them (/p13 squares, or the Pick button in /p13): marked squares
-- get a small green dot. Saved per character, since each character has its own bars.
--
-- How (no cooldown numbers needed): WoW Forever hides cooldown numbers from addons in combat
-- ("secret" values), so instead we watch each marked square's own cooldown animation. The game's
-- action button code (Blizzard_ActionBar\Shared\ActionButton.lua, read from the client) calls
-- cooldown:SetCooldown() while the square is cooling down and cooldown:Clear() when it isn't, and the
-- animation fires OnCooldownDone when it runs out. We time, with our own clock, how long each run lasted:
-- longer than the global cooldown = the spell's own cooldown just ended -> ding. The global cooldown
-- (1.5 s) after every spell is shorter than that, so it never dings.
-- A run only dings if the square still holds the same thing it held when the run started (so dragging
-- a different spell onto it, or the main bar changing page, doesn't ding).
local ADDON_NAME, ns = ...

local GCD_MAX = 1.75   -- runs this short (or shorter) are the global cooldown, not the spell's own
local SOUND = (SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_OPEN) or 5274   -- same bell as the spell-ready chime
local LOG_MAX = 40

-- The game's own bar buttons (Forever uses the modern bars). Pet bar included: hunter pet abilities.
local BARS = {
    { "ActionButton", 12 }, { "MultiBarBottomLeftButton", 12 }, { "MultiBarBottomRightButton", 12 },
    { "MultiBarRightButton", 12 }, { "MultiBarLeftButton", 12 }, { "MultiBar5Button", 12 },
    { "MultiBar6Button", 12 }, { "MultiBar7Button", 12 }, { "PetActionButton", 10 },
}

local IsSecret = issecretvalue or function() return false end

---------------------------------------------------------------------------
-- Saved squares (per character) and the debug log
---------------------------------------------------------------------------

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = (realm and realm ~= "") and realm or GetRealmName() or "?"
    return (name or "?") .. "-" .. realm
end

-- (saved under slotReadySquares: "slotReady" is the on/off option's key)
local function Squares()
    if type(P13TweaksDB.slotReadySquares) ~= "table" then P13TweaksDB.slotReadySquares = {} end
    local all, key = P13TweaksDB.slotReadySquares, CharKey()
    if type(all[key]) ~= "table" then all[key] = {} end
    return all[key]
end

local function Log(name, what, elapsed, dinged)
    if type(P13TweaksDB.slotReadyLog) ~= "table" then P13TweaksDB.slotReadyLog = {} end
    local log = P13TweaksDB.slotReadyLog
    table.insert(log, ("%s %s %s%s%s"):format(date("%H:%M:%S"), name, what,
        elapsed and (" after %.2f s"):format(elapsed) or "", dinged and " -> DING" or ""))
    while #log > LOG_MAX do table.remove(log, 1) end
end

---------------------------------------------------------------------------
-- Watching the cooldown animations
---------------------------------------------------------------------------

local buttons = {}     -- list of { name, button } found on this client
local watch = {}       -- cooldown frame -> state { name, button, active, startedAt, ident }

-- What the square holds right now, so a run that started on another spell (or another bar page)
-- doesn't ding. Returns nil if we can't tell (then it isn't compared).
local function Ident(button)
    local id
    if type(button.action) == "number" and GetActionTexture then
        local ok, tex = pcall(GetActionTexture, button.action)
        if ok and not IsSecret(tex) then id = button.action .. ":" .. tostring(tex) end
    elseif button.GetID and GetPetActionInfo then
        local ok, _, tex = pcall(GetPetActionInfo, button:GetID())
        if ok and not IsSecret(tex) then id = "pet" .. button:GetID() .. ":" .. tostring(tex) end
    end
    return id
end

local lastDing = 0
local function Ding()
    local now = GetTime()
    if now - lastDing < 0.25 then return end   -- several squares at once: one ding
    lastDing = now
    PlaySound(SOUND, "Master")
end

local function OnStart(cd)
    local s = watch[cd]
    if not s then return end
    local ident = Ident(s.button)
    if not s.active or (ident and s.ident and ident ~= s.ident) then
        s.active, s.startedAt, s.ident = true, GetTime(), ident
    end
end

local function OnEnd(cd, how)
    local s = watch[cd]
    if not (s and s.active) then return end
    s.active = false
    local elapsed = GetTime() - s.startedAt
    local ident = Ident(s.button)
    local same = not (ident and s.ident) or ident == s.ident
    local ding = elapsed > GCD_MAX and same and ns:Get("slotReady")
    if elapsed > GCD_MAX then Log(s.name, how .. (same and "" or " (square changed)"), elapsed, ding) end
    if ding then Ding() end
end

-- One hook on the shared Cooldown methods covers every square (cheap: one table lookup per call).
local hooked = false
local function HookCooldowns(sample)
    if hooked or not sample then return end
    local mt = getmetatable(sample)
    local methods = mt and mt.__index
    if type(methods) ~= "table" then return end
    hooked = true
    for _, m in ipairs({ "SetCooldown", "SetCooldownDuration", "SetCooldownUNIX", "SetCooldownFromDurationObject" }) do
        if methods[m] then hooksecurefunc(methods, m, OnStart) end
    end
    if methods.Clear then hooksecurefunc(methods, "Clear", function(cd) OnEnd(cd, "cleared") end) end
end

local function FindButtons()
    if #buttons > 0 then return end
    for _, bar in ipairs(BARS) do
        for i = 1, bar[2] do
            local name = bar[1] .. i
            local b = _G[name]
            if b and b.cooldown then table.insert(buttons, { name = name, button = b }) end
        end
    end
    if buttons[1] then HookCooldowns(buttons[1].button.cooldown) end
end

-- Marked squares: small green dot in the top-left corner (option slotReadyMarks).
local marks = {}
local function Mark(name, button, on)
    local m = marks[name]
    if on and not m then
        m = CreateFrame("Frame", nil, button)
        m:SetSize(10, 10)
        m:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        m:SetFrameLevel(button:GetFrameLevel() + 6)
        local t = m:CreateTexture(nil, "OVERLAY")
        t:SetAllPoints()
        t:SetTexture("Interface\\AddOns\\P13Tweaks\\Media\\Blob.tga")
        t:SetVertexColor(0.2, 1, 0.4, 1)
        marks[name] = m
    end
    if m then m:SetShown(on) end
end

local pendingApply = false
local function Apply()
    if InCombatLockdown() then pendingApply = true; return end   -- (marks are children of the bar buttons)
    pendingApply = false
    FindButtons()
    local sq = Squares()
    for _, e in ipairs(buttons) do
        local cd = e.button.cooldown
        local on = sq[e.name] and true or false
        if on and not watch[cd] then
            watch[cd] = { name = e.name, button = e.button, active = false }
            if not e.doneHooked then
                e.doneHooked = true
                cd:HookScript("OnCooldownDone", function(self) OnEnd(self, "done") end)
            end
            -- (one already cooling is picked up by the game's next cooldown update - every cast
            -- sends one - and timed from then; starting it here could ding for an idle square)
        elseif not on then
            watch[cd] = nil
        end
        Mark(e.name, e.button, on and ns:Get("slotReadyMarks"))
    end
end

---------------------------------------------------------------------------
-- Pick mode: a clickable overlay on every visible square
---------------------------------------------------------------------------

local overlays, banner = {}, nil
local StopPicking

local function PaintOverlay(o)
    local on = Squares()[o.name]
    if on then
        o.fill:SetColorTexture(0.1, 0.9, 0.3, 0.45)
    else
        o.fill:SetColorTexture(0, 0, 0, 0.35)
    end
    o.check:SetShown(on and true or false)
end

local function MakeOverlay(e)
    local o = CreateFrame("Button", nil, UIParent)
    o:SetFrameStrata("DIALOG")
    o:SetAllPoints(e.button)
    o.name = e.name
    o.fill = o:CreateTexture(nil, "BACKGROUND")
    o.fill:SetAllPoints()
    o.check = o:CreateTexture(nil, "OVERLAY")
    o.check:SetSize(22, 22)
    o.check:SetPoint("CENTER")
    o.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    o:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    o:SetScript("OnClick", function(self)
        local sq = Squares()
        sq[self.name] = (not sq[self.name]) or nil
        PaintOverlay(self)
        Apply()
    end)
    o:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(Squares()[self.name] and "Dings when ready" or "Click to ding when ready")
        GameTooltip:AddLine("Click again to switch it off.", 1, 1, 1)
        GameTooltip:Show()
    end)
    o:SetScript("OnLeave", function() GameTooltip:Hide() end)
    overlays[e.name] = o
    return o
end

local function MakeBanner()
    local f = CreateFrame("Frame", "P13TweaksSlotPickBanner", UIParent, "BackdropTemplate")
    f:SetSize(430, 64)
    f:SetPoint("TOP", 0, -120)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
    f:SetBackdropBorderColor(0.2, 1, 0.6, 1)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("TOP", 0, -10)
    t:SetWidth(410)
    t:SetText("Click the action bar squares that should |cff33ff99ding|r when they're ready.\nGreen = marked. Click again to unmark.")
    local done = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    done:SetSize(80, 20)
    done:SetPoint("BOTTOM", 0, 6)
    done:SetText("Done")
    done:SetScript("OnClick", function() StopPicking() end)
    -- (hidden BEFORE the OnHide script is set: hiding it after used to run StopPicking on the very first
    -- Pick, before any overlay existed, so the first Done then found nothing to stop)
    f:Hide()
    f:SetScript("OnHide", function() StopPicking() end)
    tinsert(UISpecialFrames, f:GetName())   -- Escape finishes too
    return f
end

local picking = false
function StopPicking()
    for _, o in pairs(overlays) do o:Hide() end   -- always, even if we think we've stopped already
    if banner and banner:IsShown() then banner:Hide() end
    if not picking then return end
    picking = false
    local n = 0
    for _ in pairs(Squares()) do n = n + 1 end
    ns:Print(("%d square%s will ding when ready."):format(n, n == 1 and "" or "s")
        .. (ns:Get("slotReady") and "" or " (The option is OFF in /p13.)"))
end

local function StartPicking()
    if InCombatLockdown() then ns:Print("can't pick squares in combat."); return end
    FindButtons()
    if #buttons == 0 then ns:Print("couldn't find the game's action bar buttons (an action bar addon?)."); return end
    if ns.optionsFrame and ns.optionsFrame:IsShown() then ns.optionsFrame:Hide() end
    picking = true
    banner = banner or MakeBanner()
    banner:Show()
    for _, e in ipairs(buttons) do
        if e.button:IsVisible() then
            local o = overlays[e.name] or MakeOverlay(e)
            PaintOverlay(o)
            o:Show()
        elseif overlays[e.name] then
            overlays[e.name]:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Options, commands, events
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "slotReady",
    type = "toggleButton",
    label = "Ding when a marked action bar square is ready",
    buttonText = "Pick",
    buttonWidth = 60,
    onClick = function() StartPicking() end,
    tooltip = "Pick squares on your action bars (Pick, or /p13 squares): whatever spell or item is on a marked square plays a ding the moment its cooldown ends. Works in combat too. The global cooldown after every spell doesn't ding.\n\nSaved per character. The pet bar works too. /p13 squares clear unmarks them all.",
    default = true,
})

ns:RegisterOption({
    key = "slotReadyMarks",
    type = "toggle",
    label = "Show a green dot on marked squares",
    tooltip = "A small green dot in the top-left corner of each action bar square that dings when ready.",
    default = true,
    onChange = function() Apply() end,
})

ns:RegisterCommand("squares", "pick action bar squares that ding when ready (clear / debug)", function(rest)
    rest = (rest or ""):lower()
    if rest == "clear" then
        wipe(Squares())
        Apply()
        ns:Print("unmarked every square.")
    elseif rest == "debug" then
        FindButtons()
        local sq, found, marked = Squares(), {}, {}
        for _, e in ipairs(buttons) do
            table.insert(found, e.name .. (e.button:IsVisible() and "" or " (hidden)"))
            if sq[e.name] then
                local s = watch[e.button.cooldown]
                table.insert(marked, ("%s action=%s ident=%s active=%s"):format(e.name, tostring(e.button.action),
                    tostring(Ident(e.button)), tostring(s and s.active)))
            end
        end
        P13TweaksDB.slotReadyDebug = { time = date("%Y-%m-%d %H:%M:%S"), version = ns.version, hooked = hooked,
            option = ns:Get("slotReady"), found = found, marked = marked, log = P13TweaksDB.slotReadyLog }
        ns:Print(("found %d squares, %d marked, hooks %s. Saved - /reload so it's written to disk."):format(
            #found, #marked, hooked and "on" or "MISSING"))
    else
        StartPicking()
    end
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        Apply()
    elseif event == "PLAYER_REGEN_DISABLED" then
        if picking and banner then banner:Hide() end   -- (stops picking)
    elseif event == "PLAYER_REGEN_ENABLED" and pendingApply then
        Apply()
    end
end)

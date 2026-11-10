-- P13Tweaks feature: hide the chat window until you hover over it.
-- Chat fades out when the mouse is away and fades back in when the cursor is over
-- where the chat sits (or its tabs), when you press Enter to type, or (option) for a few
-- seconds when a new message shows up in the chat window you're looking at.
-- The frames are only made transparent (never hidden), so nothing about chat itself changes.
local ADDON_NAME, ns = ...

local MARGIN      = 0      -- extra UI pixels around the chat box that also count (0 = must be on it)
local DELAY       = 1.0    -- seconds to wait after the cursor leaves before fading out
local FADE_IN     = 0.15   -- seconds to fade fully in
local FADE_OUT    = 0.5    -- seconds to fade fully out
local CHECK_EVERY = 0.05
local DEFAULT_SHOW_SECS = 5   -- how long a new message keeps chat visible

-- Chat-side buttons that should fade along with the chat (whichever exist in this client).
local EXTRA = {
    "GeneralDockManager", "ChatFrameMenuButton", "ChatFrameChannelButton",
    "ChatFrameToggleVoiceDeafenButton", "ChatFrameToggleVoiceMuteButton",
    "QuickJoinToastButton", "FriendsMicroButton", "ChatAlertFrame",
}

local alpha = 1          -- our multiplier on top of whatever alpha Blizzard wants
local active = false     -- feature on?
local guard = false      -- stops our SetAlpha hook from reacting to our own calls
local hooked = {}        -- frame -> true once its SetAlpha is hooked
local fadeable = {}      -- list of frames we fade
local showUntil = 0      -- GetTime() until which a new message keeps chat visible
local msgHooked = {}     -- chat frame -> true once its AddMessage is hooked

-- A new line in a chat window that's actually on screen (its tab is the selected one)
-- brings chat back for a few seconds. Only the timing is used, never the message.
local function HookMessages(cf)
    if msgHooked[cf] or not cf.AddMessage then return end
    msgHooked[cf] = true
    hooksecurefunc(cf, "AddMessage", function(self)
        if active and ns:Get("chatFadeShowNew") and self:IsShown() then
            showUntil = GetTime() + (ns:Get("chatFadeShowSecs") or DEFAULT_SHOW_SECS)
        end
    end)
end

-- Blizzard fades chat tabs etc. by calling SetAlpha. We remember the alpha it asked for
-- (frame.p13WantAlpha) and multiply it by ours, so both fades work together.
local function Apply(f)
    guard = true
    f:SetAlpha((f.p13WantAlpha or 1) * alpha)
    guard = false
end

local function Track(f)
    if not f or hooked[f] then return end
    hooked[f] = true
    f.p13WantAlpha = f:GetAlpha()
    table.insert(fadeable, f)
    hooksecurefunc(f, "SetAlpha", function(self, a)
        if guard then return end
        self.p13WantAlpha = a
        if active and alpha < 1 then Apply(self) end
    end)
end

local function ChatFrameNames()
    if CHAT_FRAMES then return CHAT_FRAMES end
    local t = {}
    for i = 1, (NUM_CHAT_WINDOWS or 10) do t[i] = "ChatFrame" .. i end
    return t
end

-- Pick up chat windows (including whisper windows opened later) and their parts.
local function Collect()
    for _, name in ipairs(ChatFrameNames()) do
        local cf = _G[name]
        if cf then
            Track(cf)
            HookMessages(cf)
            Track(_G[name .. "Tab"])
            Track(_G[name .. "ButtonFrame"])
            Track(_G[name .. "EditBox"])
        end
    end
    for _, name in ipairs(EXTRA) do Track(_G[name]) end
end

local function CursorNear(f, x, y, m)
    if not (f and f:IsVisible()) then return false end
    local l, r, b, t = f:GetLeft(), f:GetRight(), f:GetBottom(), f:GetTop()
    if not l then return false end
    local s = f:GetEffectiveScale()
    return x >= l * s - m and x <= r * s + m and y >= b * s - m and y <= t * s + m
end

local function Typing()
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return true end
    for _, name in ipairs(ChatFrameNames()) do
        local eb = _G[name .. "EditBox"]
        if eb and eb:HasFocus() then return true end
    end
    return false
end

local function WantVisible()
    if Typing() or GetTime() < showUntil then return true end
    local x, y = GetCursorPosition()
    local m = MARGIN * UIParent:GetEffectiveScale()
    for _, name in ipairs(ChatFrameNames()) do
        if CursorNear(_G[name], x, y, m) or CursorNear(_G[name .. "Tab"], x, y, m) then return true end
    end
    return CursorNear(GeneralDockManager, x, y, m)
end

local frame = CreateFrame("Frame")
frame:Hide()
local since, awaySince, collectSince = 0, 0, 0

frame:SetScript("OnUpdate", function(self, dt)
    since = since + dt
    if since < CHECK_EVERY then return end
    dt, since = since, 0

    collectSince = collectSince + dt
    if collectSince > 2 then collectSince = 0; Collect() end

    local target
    if WantVisible() then
        awaySince, target = 0, 1
    else
        awaySince = awaySince + dt
        target = (awaySince >= DELAY) and 0 or 1
    end
    if alpha == target then return end
    if target > alpha then
        alpha = math.min(1, alpha + dt / FADE_IN)
    else
        alpha = math.max(0, alpha - dt / FADE_OUT)
    end
    for _, f in ipairs(fadeable) do Apply(f) end
end)

local function Update()
    active = ns:Get("chatFade") and true or false
    Collect()
    alpha, awaySince = 1, 0
    for _, f in ipairs(fadeable) do Apply(f) end
    frame:SetShown(active)
end

ns:RegisterOption({
    key = "chatFade",
    type = "toggle",
    label = "Hide chat until I hover over it",
    tooltip = "Chat fades away when your mouse isn't on it. Hover over the spot where chat sits (or its tabs), or press Enter to type, and it fades right back in. Type /p13 chat to switch this on or off quickly.",
    default = true,
    onChange = Update,
})

ns:RegisterOption({
    key = "chatFadeShowNew",
    type = "toggleNumber",
    label = "Show hidden chat when a message arrives",
    before = "Show chat for",
    after = "seconds when a message arrives",
    numberKey = "chatFadeShowSecs",
    numberDefault = DEFAULT_SHOW_SECS,
    tooltip = "While chat is hidden, a new message in the chat window you have selected fades it back in for this many seconds (then about 1.5 more to fade out). Messages in other tabs don't count. Only matters when \"Hide chat until I hover over it\" is on.",
    default = true,
    onChange = function() showUntil = 0 end,
})

ns:RegisterCommand("chat", "turn hide-chat-until-hovered on or off", function()
    ns:Set("chatFade", not ns:Get("chatFade"))
    ns:RefreshOptions()
    ns:Print("Hide chat until hovered: " .. (ns:Get("chatFade") and "ON" or "OFF"))
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function() Update() end)

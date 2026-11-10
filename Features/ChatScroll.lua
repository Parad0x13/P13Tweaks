-- P13Tweaks feature: one mouse-wheel notch scrolls chat exactly one line.
-- Shift + wheel jumps to the top/bottom, Ctrl + wheel scrolls a page at a time.
local ADDON_NAME, ns = ...

local original = {}   -- chat frame -> its original OnMouseWheel script (restored when turned off)

local function OnWheel(self, delta)
    if IsShiftKeyDown() then
        if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
    elseif IsControlKeyDown() then
        if delta > 0 then self:PageUp() else self:PageDown() end
    elseif self.SetScrollOffset and self.GetScrollOffset then
        -- Offset counts lines up from the bottom; clamp so we never scroll past either end.
        local offset = self:GetScrollOffset() + (delta > 0 and 1 or -1)
        local max = self.GetMaxScrollRange and self:GetMaxScrollRange()
        if max then offset = math.min(offset, max) end
        self:SetScrollOffset(math.max(0, offset))
    else
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end
end

local function ChatFrames()
    local list = {}
    local names = CHAT_FRAMES
    if not names then
        names = {}
        for i = 1, (NUM_CHAT_WINDOWS or 10) do names[i] = "ChatFrame" .. i end
    end
    for _, name in ipairs(names) do
        if _G[name] then table.insert(list, _G[name]) end
    end
    return list
end

local function Setup(cf)
    if original[cf] == nil then original[cf] = cf:GetScript("OnMouseWheel") or false end
    if ns:Get("chatScrollOne") then
        cf:EnableMouseWheel(true)
        cf:SetScript("OnMouseWheel", OnWheel)
    else
        cf:SetScript("OnMouseWheel", original[cf] or nil)
    end
end

local function Update()
    for _, cf in ipairs(ChatFrames()) do Setup(cf) end
end

ns:RegisterOption({
    key = "chatScrollOne",
    type = "toggle",
    label = "Mouse wheel scrolls chat one line at a time",
    tooltip = "Each notch of the mouse wheel moves chat by exactly one line. Hold Shift to jump to the top/bottom, or Ctrl to scroll a page at a time.",
    default = true,
    onChange = Update,
})

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    Update()
    -- Whisper/pet-battle windows are created later; set those up too.
    if FCF_OpenTemporaryWindow then
        hooksecurefunc("FCF_OpenTemporaryWindow", function() Update() end)
    end
end)

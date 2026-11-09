-- P13Tweaks feature: show the game's floating "interact" icon over nearby objects (herbs, ore,
-- chests, mailboxes...). Uses the client's built-in soft-target settings; turning the option
-- off puts those settings back to the game's defaults.
local ADDON_NAME, ns = ...

local SETTINGS = {
    SoftTargetInteract         = "3",   -- always pick a nearby interactable as soft target
    SoftTargetInteractArc      = "2",   -- look all around you, not just in front
    SoftTargetInteractRange    = "60",  -- yards
    SoftTargetIconInteract     = "1",   -- show the icon
    SoftTargetIconGameObject   = "1",   -- ...over objects like herbs and ore
    SoftTargetLowPriorityIcons = "1",   -- include lower-priority objects too
}

local GetCV = (C_CVar and C_CVar.GetCVar) or GetCVar
local SetCV = (C_CVar and C_CVar.SetCVar) or SetCVar
local GetDefault = (C_CVar and C_CVar.GetCVarDefault) or GetCVarDefault

local pendingAfterCombat = false

local function Apply(on)
    if InCombatLockdown() then pendingAfterCombat = true; return end
    for name, value in pairs(SETTINGS) do
        if GetCV(name) ~= nil then  -- skip any setting this client doesn't have
            local v = value
            if not on then v = GetDefault and GetDefault(name) end
            if v then SetCV(name, v) end
        end
    end
end

ns:RegisterOption({
    key = "interactIcons",
    type = "toggle",
    label = "Show icons over nearby herbs and objects",
    tooltip = "Uses the game's soft-target system to float an icon over the nearest interactable object within 60 yards (herbs, ore, chests, mailboxes...). It can't be limited to herbs. Turning this off resets those settings to the game defaults.",
    default = true,
    onChange = Apply,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        -- Only touch settings at login if enabled, so disabling isn't re-applied every login.
        if ns:Get("interactIcons") then Apply(true) end
    elseif pendingAfterCombat then
        pendingAfterCombat = false
        Apply(ns:Get("interactIcons"))
    end
end)

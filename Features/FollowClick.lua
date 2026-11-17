-- P13Tweaks feature: Shift + left-click a player's portrait to follow them.
-- Works on the party member frames, the compact party / raid frames and the target frame. It sets the
-- frames' own secure "shift-click" action to the macro "/follow mouseover" (the same thing as typing
-- /follow while pointing at them). Secure frames can only be changed out of combat, so a change made during
-- combat waits until it ends.
local ADDON_NAME, ns = ...

local MACRO = "/follow mouseover"

local function On() return ns:Get("followClick") end

-- Every unit frame we know of that can be shift-clicked.
local function Frames()
    local list = {}
    local function Add(f) if f and f.SetAttribute then list[#list + 1] = f end end
    for i = 1, 4 do Add(_G["PartyMemberFrame" .. i]) end
    for i = 1, 5 do Add(_G["CompactPartyFrameMember" .. i]) end
    for i = 1, 40 do Add(_G["CompactRaidFrame" .. i]) end
    Add(_G.TargetFrame)
    return list
end

local pending = false

local function Apply()
    if InCombatLockdown() then pending = true; return end
    pending = false
    local on = On()
    for _, f in ipairs(Frames()) do
        pcall(function()
            if on then
                f:SetAttribute("shift-type1", "macro")
                f:SetAttribute("shift-macrotext1", MACRO)
            elseif f:GetAttribute("shift-macrotext1") == MACRO then   -- only undo what we set
                f:SetAttribute("shift-type1", nil)
                f:SetAttribute("shift-macrotext1", nil)
            end
        end)
    end
end

ns:RegisterOption({
    key = "followClick",
    type = "toggle",
    label = "Shift-click a player's portrait to follow them",
    tooltip = "Hold Shift and left-click a party member's, raid member's or your target's portrait to follow them (the same as typing /follow while pointing at them). Works out of combat; a change made in combat applies when it ends.",
    default = true,
    onChange = function() Apply() end,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")   -- raid / party frames appear as the group changes
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and not pending then return end
    C_Timer.After(0.5, Apply)
end)

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
    if _G.PartyFrame then
        for i = 1, 4 do Add(_G.PartyFrame["MemberFrame" .. i]) end   -- the newer-style party frame
    end
    for i = 1, 5 do Add(_G["CompactPartyFrameMember" .. i]) end
    for i = 1, 40 do Add(_G["CompactRaidFrame" .. i]) end
    Add(_G.TargetFrame)
    return list
end

local pending = false

-- Shift + left-click on a player standing in the world (the 3D character). A click on the world isn't a click on a
-- frame, so the world frame's mouse events are watched instead (see below).
-- (The game handles plain clicks on the 3D world itself, so a key binding on Shift+left-click never fires there.
-- Instead the world frame's mouse events are watched: on a Shift+left press over a friendly player, remember who;
-- on release, follow them - unless the mouse was dragged to turn the camera.)
local worldHooked, pressed, px, py = false, nil, 0, 0

local function SetupWorld()
    if worldHooked or not _G.WorldFrame then return end
    worldHooked = true
    WorldFrame:HookScript("OnMouseDown", function(_, button)
        pressed = nil
        if button ~= "LeftButton" or not IsShiftKeyDown() or not (On() and ns:Get("followClickWorld")) then return end
        if UnitExists("mouseover") and UnitIsPlayer("mouseover") and not UnitIsUnit("mouseover", "player")
            and UnitIsFriend("player", "mouseover") and not UnitIsDeadOrGhost("mouseover") then
            pressed = GetUnitName("mouseover", true)
            px, py = GetCursorPosition()
        end
    end)
    WorldFrame:HookScript("OnMouseUp", function(_, button)
        local who = pressed
        pressed = nil
        if button ~= "LeftButton" or not who then return end
        local x, y = GetCursorPosition()
        if math.abs(x - px) + math.abs(y - py) > 8 then return end   -- dragged: that was a camera turn
        pcall(FollowUnit, who)
    end)
end

local function Apply()
    if InCombatLockdown() then pending = true; return end
    pending = false
    pcall(SetupWorld)
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

ns:RegisterOption({
    key = "followClickWorld",
    type = "toggle",
    label = "...and Shift-click a player in the world to follow them",
    tooltip = "Hold Shift and left-click another player's character (standing in the game world) to follow them. Dragging to turn the camera doesn't count. Clicks on windows and unit frames are not affected.",
    default = true,
    onChange = function() Apply() end,
})

ns:RegisterCommand("followdebug", "show which unit frames Shift-click-follow found (for troubleshooting)", function()
    local n = 0
    for _, f in ipairs(Frames()) do
        n = n + 1
        local ok, mt = pcall(f.GetAttribute, f, "shift-macrotext1")
        ns:Print(("frame %s: %s"):format(tostring(f.GetName and f:GetName() or "?"), (ok and mt) and "Shift-click follow set" or "NOT set"))
    end
    if n == 0 then ns:Print("No party / raid / target frames found.") end
    ns:Print("World Shift-click follow hooked: " .. tostring(worldHooked))
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")   -- raid / party frames appear as the group changes
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and not pending then return end
    C_Timer.After(0.5, Apply)
end)

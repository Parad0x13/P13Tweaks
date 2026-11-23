-- P13Tweaks feature: a "Party" button on the world map that centres the map on your party members in turn.
-- Left-click: the next member (after the last one it comes back to you). Right-click: the previous one.
-- Members the map can't show (another instance, offline, too far for the game to report) are skipped.
-- In a raid it goes through the raid instead. Keeps the current zoom; centring is MapCenterKey.lua's.
local ADDON_NAME, ns = ...

local button
local pos = 0          -- 0 = you; 1..n = the n-th member of the list below
local lastRoster       -- (the list is rebuilt each click; if it changed, start again from you)

-- Everyone to cycle through, you last: party1..4, or the raid without you.
local function Roster()
    local list = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local u = "raid" .. i
            if UnitExists(u) and not UnitIsUnit(u, "player") then list[#list + 1] = u end
        end
    else
        for i = 1, GetNumSubgroupMembers() do
            local u = "party" .. i
            if UnitExists(u) then list[#list + 1] = u end
        end
    end
    return list
end

local function SetLabel(unit)
    if not button then return end
    if not unit or unit == "player" then
        button:SetText("Party")
    else
        local name = UnitName(unit)
        if not name or (issecretvalue and issecretvalue(name)) then name = "?" end
        button:SetText(name)
    end
end

-- step +1 (next) or -1 (previous); tries each member at most once, skipping ones not on a map
local function Cycle(step)
    if not (ns.CentreMapOnPlayer and WorldMapFrame:IsShown()) then return end
    local list = Roster()
    local key = table.concat(list, ",")
    if key ~= lastRoster then pos, lastRoster = 0, key end
    local n = #list
    if n == 0 then return end
    for _ = 1, n + 1 do
        pos = (pos + step) % (n + 1)          -- 0 is you
        local unit = pos == 0 and "player" or list[pos]
        if ns.CentreMapOnPlayer(false, unit) then
            SetLabel(unit)
            return
        end
    end
    SetLabel(nil)
end

local function Refresh()
    if not button then return end
    local show = ns:Get("mapPartyCycle") and IsInGroup()
    button:SetShown(show and true or false)
    if not show then pos, lastRoster = 0, nil; SetLabel(nil) end
end

ns:RegisterOption({
    key = "mapPartyCycle",
    type = "toggle",
    label = "Party button on the map (centre on each party member in turn)",
    tooltip = "While you're in a group, a Party button on the world map centres the map on your party members one after another, then back on you. Right-click goes the other way. In a raid it goes through the raid.",
    default = true,
    onChange = Refresh,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
        if not sc then return end
        button = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
        button:SetSize(90, 22)
        button:SetText("Party")
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetScript("OnClick", function(_, mb) Cycle(mb == "RightButton" and -1 or 1) end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:SetText("Centre on party")
            GameTooltip:AddLine("Left-click: centre the map on the next party member (then back on you).", 1, 1, 1, true)
            GameTooltip:AddLine("Right-click: the previous one.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ns:AddMapButton(button, 20)
        -- each time the map opens, the cycle starts again from you
        WorldMapFrame:HookScript("OnHide", function() pos = 0; SetLabel(nil) end)
    end
    Refresh()
end)

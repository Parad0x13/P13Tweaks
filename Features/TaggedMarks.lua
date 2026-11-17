-- P13Tweaks feature: a skull above every enemy one of your teammates is targeting (has "tagged").
-- It reads your group members' targets (party1target ... raid40target), which the game tells you for anyone in
-- range, so it works even with teammates who don't have P13Tweaks. The skull is drawn on the enemy's nameplate, so
-- enemy nameplates must be on (the game's "Enemy nameplates" setting, "V" by default).
local ADDON_NAME, ns = ...

local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"   -- the game's skull raid marker picture
local SIZE = 24
local TICK = 0.2

local function On() return ns:Get("taggedMarks") end

-- GUIDs of the enemies my group members are targeting right now.
local function TaggedGuids()
    local set = {}
    if not IsInGroup() then return set end
    local raid = IsInRaid()
    for i = 1, (GetNumGroupMembers() or 0) do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local t = unit .. "target"
            if UnitExists(t) and not UnitIsDead(t) and UnitCanAttack("player", t) then
                local guid = UnitGUID(t)
                if guid then set[guid] = true end
            end
        end
    end
    return set
end

local function IconFor(plate)
    if plate.p13Skull then return plate.p13Skull end
    local anchor = plate.UnitFrame or plate
    local f = CreateFrame("Frame", nil, plate)
    f:SetSize(SIZE, SIZE)
    f:SetFrameLevel((plate:GetFrameLevel() or 1) + 5)
    f:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    t:SetTexture(SKULL)
    f:Hide()
    plate.p13Skull = f
    return f
end

local function Update()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local plates = C_NamePlate.GetNamePlates()
    if not On() then
        for _, plate in ipairs(plates) do if plate.p13Skull then plate.p13Skull:Hide() end end
        return
    end
    local tagged = TaggedGuids()
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        local show = false
        if unit and next(tagged) ~= nil then
            local guid = UnitGUID(unit)
            show = guid and tagged[guid] and not UnitIsDead(unit) and true or false
        end
        if show then
            IconFor(plate):Show()
        elseif plate.p13Skull then
            plate.p13Skull:Hide()
        end
    end
end

ns:RegisterOption({
    key = "taggedMarks",
    type = "toggle",
    label = "Skull above enemies my teammates are fighting",
    tooltip = "Puts a skull above the nameplate of every enemy one of your group members is targeting, so you can tell which ones are already taken. Works with any group member (they don't need P13Tweaks) and needs enemy nameplates turned on in the game's settings (\"V\" by default).",
    default = true,
    onChange = function() Update() end,
})

local since = 0
local frame = CreateFrame("Frame")
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
frame:SetScript("OnEvent", function(_, event, unit)
    -- plates are reused for other enemies: clear our skull as one is taken away
    local plate = unit and C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    if plate and plate.p13Skull then plate.p13Skull:Hide() end
end)
frame:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since < TICK then return end
    since = 0
    Update()
end)

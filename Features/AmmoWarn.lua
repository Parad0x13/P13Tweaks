-- P13Tweaks feature: hunters get a warning when their arrows / bullets run low.
-- Ammo lives in inventory slot 0 (the ammo slot). Clients without an ammo slot (e.g. MoP) never warn.
local ADDON_NAME, ns = ...

local DEFAULT_LOW = 100
local AMMO_SLOT, RANGED_SLOT = 0, 18

local state = "ok"   -- "ok", "low" or "out": the level already warned about

local function IsHunter()
    local _, class = UnitClass("player")
    return class == "HUNTER"
end

-- "arrows" or "bullets", from the equipped ranged weapon (nil if it takes no ammo)
local function AmmoWord()
    local link = GetInventoryItemLink("player", RANGED_SLOT)
    if not link then return nil end
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInfo then return "arrows" end
    local _, _, _, _, _, classID, subID = getInfo(link)
    if classID ~= 2 then return nil end
    if subID == 3 then return "bullets" end
    if subID == 2 or subID == 18 then return "arrows" end
    return nil
end

local function Warn(text)
    ns:Print("|cffff4040" .. text .. "|r")
    if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 1, 0.25, 0.25, 1) end
    if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end

local function Check(quiet)
    if not ns:Get("ammoWarn") or not IsHunter() then return end
    local word = AmmoWord()
    if not word then state = "ok"; return end
    local count = 0
    if GetInventoryItemID("player", AMMO_SLOT) then
        count = GetInventoryItemCount("player", AMMO_SLOT) or 0
    end
    local low = tonumber(ns:Get("ammoWarnLow")) or DEFAULT_LOW
    local new
    if count <= 0 then new = "out"
    elseif count <= low then new = "low"
    else new = "ok" end
    if new == state then return end
    local old = state
    state = new
    if quiet and new == "low" then return end
    if new == "out" then
        Warn("You are out of " .. word .. "!")
    elseif new == "low" and old == "ok" then
        Warn("Running low on " .. word .. ": " .. count .. " left.")
    end
end

ns:RegisterOption({
    key = "ammoWarn",
    type = "toggleNumber",
    label = "Hunter low-ammo warning",
    before = "Warn when ammo is at or below",
    after = "left",
    numberKey = "ammoWarnLow",
    numberDefault = DEFAULT_LOW,
    tooltip = "Hunters only: shows a warning (screen text, chat and a sound) when the arrows or bullets in your ammo slot drop to this number, and again when you run out. Needs a bow, crossbow or gun equipped.",
    default = true,
    onChange = function() state = "ok"; Check(false) end,
})

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        state = "ok"
        Check(false)
    else
        Check(false)
    end
end)

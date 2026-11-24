-- P13Tweaks feature: hunters get an on-screen notice when their arrows / bullets run low,
-- styled like the profession-cap notice (ProfCap.lua): a small gold-bordered box that stays
-- up until you restock. Left-click: waypoint to the nearest ammo vendor (needs QuestieDB).
-- Drag to move. Right-click to hide it until the level changes (low -> out, or restocked).
-- Ammo lives in inventory slot 0 (the ammo slot). Clients without an ammo slot (e.g. MoP) never warn.
local ADDON_NAME, ns = ...

local DEFAULT_LOW = 100
local AMMO_SLOT, RANGED_SLOT = 0, 18

local state = "ok"      -- "ok", "low" or "out"
local dismissed = nil   -- the state the player right-clicked away (session only)

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

---------------------------------------------------------------------------
-- The notice
---------------------------------------------------------------------------

local frame = CreateFrame("Button", "P13TweaksAmmoWarn", UIParent, "BackdropTemplate")
frame:SetSize(220, 46)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
if frame.SetBackdrop then
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
    frame:SetBackdropBorderColor(1, 0.82, 0, 0.9)
end
frame:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
frame:Hide()

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -8)

local line = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
line:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
line:SetJustifyH("LEFT")

local function Place()
    frame:ClearAllPoints()
    local p = P13TweaksDB.ammoWarnPos
    if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint("TOP", UIParent, "TOP", 0, -190) end
end

local dragging = false
frame:SetScript("OnDragStart", function() dragging = true; frame:StartMoving() end)
frame:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    local point, _, relPoint, x, y = frame:GetPoint()
    P13TweaksDB.ammoWarnPos = { point, relPoint, x, y }
    C_Timer.After(0, function() dragging = false end)   -- the drag's mouse-up also fires OnClick
end)

local Check

local function GuideToAmmo()
    if not ns.GuideToNpc then return end
    -- (also used by "Mark closest Ammo vendor" in the portrait right-click menu, ProfCap.lua)
    if not ns.GuideToNpc("AMMO", "Ammo vendor") then
        ns:Print("|cffffd200No ammo vendor (bowyer / gunsmith) found nearby - trying General Goods, who often sell basic ammo.|r")
        if not ns.GuideToNpc("GOODS", "General Goods") then
            ns:Print("No ammo vendor or General Goods vendor found in QuestieDB.")
        end
    end
end

frame:SetScript("OnClick", function(_, button)
    if dragging then return end
    if button == "RightButton" then
        dismissed = state
        frame:Hide()
    else
        GuideToAmmo()
    end
end)
frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Low ammo", 1, 1, 1)
    GameTooltip:AddLine("Left-click: waypoint to the nearest ammo vendor.", nil, nil, nil, true)
    GameTooltip:AddLine("Drag to move. Right-click to hide until you run out or restock.", nil, nil, nil, true)
    GameTooltip:Show()
end)
frame:SetScript("OnLeave", GameTooltip_Hide)

local function Show(word, count, out)
    local Word = word:gsub("^%l", string.upper)
    title:SetText(Word .. " " .. (out and "gone" or "running low") .. " - visit a vendor")
    local tex = GetInventoryItemTexture("player", AMMO_SLOT)
    local icon = tex and ("|T" .. tex .. ":14:14:0:0|t ") or ""
    local color = out and "|cffff4040" or "|cffffa020"
    line:SetText(("%s%s  %s%d left|r%s"):format(icon, Word, color, count, out and "  |cffff4040OUT|r" or ""))
    frame:SetSize(math.max(title:GetStringWidth(), line:GetStringWidth()) + 20, 46)
    frame:Show()
end

Check = function()
    if not P13TweaksDB or not ns:Get("ammoWarn") or not IsHunter() then frame:Hide(); return end
    local word = AmmoWord()
    if not word then state = "ok"; frame:Hide(); return end
    local count = 0
    if GetInventoryItemID("player", AMMO_SLOT) then
        count = GetInventoryItemCount("player", AMMO_SLOT) or 0
    end
    local low = tonumber(ns:Get("ammoWarnLow")) or DEFAULT_LOW
    local new
    if count <= 0 then new = "out"
    elseif count <= low then new = "low"
    else new = "ok" end

    if new ~= state then
        local old = state
        state = new
        if dismissed and dismissed ~= new then dismissed = nil end   -- level changed: show again
        -- A sound when it first goes low, and again when you run out.
        if (new == "out" or (new == "low" and old == "ok")) and SOUNDKIT and SOUNDKIT.RAID_WARNING then
            PlaySound(SOUNDKIT.RAID_WARNING)
        end
    end

    if new == "ok" or dismissed == new then frame:Hide(); return end
    Show(word, count, new == "out")
end

ns:RegisterOption({
    key = "ammoWarn",
    type = "toggleNumber",
    label = "Hunter low-ammo notice",
    before = "Warn when ammo is at or below",
    after = "left",
    numberKey = "ammoWarnLow",
    numberDefault = DEFAULT_LOW,
    tooltip = "Hunters only: puts a small notice on screen (like the profession-cap one) when the arrows or bullets in your ammo slot drop to this number (orange), and when you run out (red, OUT), with a warning sound. It stays up until you restock.\n\nClick the notice for a waypoint to the nearest ammo vendor (needs QuestieDB). Drag it to move; right-click to hide it until you run out or restock. Needs a bow, crossbow or gun equipped.",
    default = true,
    onChange = function() state = "ok"; dismissed = nil; Check() end,
})

ns.GuideToAmmo = GuideToAmmo
ns:RegisterCommand("ammo","waypoint to the nearest ammo vendor (bowyer / gunsmith)", GuideToAmmo)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then Place() end
    Check()
end)

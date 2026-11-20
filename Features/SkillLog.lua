-- P13Tweaks feature: log how often you use certain skills (default "Sinister Strike") and give
-- outside software a way to notice each use.
-- Addons can't write files while the game runs, so there are two outputs:
--   1. The log: per-skill totals and the last casts (with times) saved in P13TweaksDB, so they end
--      up in WTF\Account\<account>\SavedVariables\P13Tweaks.lua when you /reload or log out.
--   2. The beacon: a small square in the top-left corner of the screen whose colour encodes the
--      running cast total (red*65536 + green*256 + blue). It changes on every cast, so a program
--      that watches that screen pixel sees each use as it happens (needs windowed/borderless mode).
-- Sinister Strike has no cooldown of its own (only the global cooldown), so this counts casts.
local ADDON_NAME, ns = ...

local DEFAULT_SPELLS = "Sinister Strike"
local MAX_LOG = 500
local BEACON_SIZE = 8

local IsSecret = issecretvalue or function() return false end

local tracked = {}   -- lower-cased name -> display name
local function ReadNames()
    wipe(tracked)
    for name in (ns:Get("skillLogNames") or ""):gmatch("[^,]+") do
        name = strtrim(name)
        if name ~= "" then tracked[name:lower()] = name end
    end
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return (GetSpellInfo(id))
end

---------------------------------------------------------------------------
-- The beacon
---------------------------------------------------------------------------

local beacon = CreateFrame("Frame", "P13TweaksSkillBeacon", UIParent)
beacon:SetSize(BEACON_SIZE, BEACON_SIZE)
beacon:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
beacon:SetFrameStrata("TOOLTIP")
beacon:Hide()
local tex = beacon:CreateTexture(nil, "OVERLAY")
tex:SetAllPoints()
tex:SetColorTexture(0, 0, 0, 1)

local function SetBeacon(total)
    total = total % 16777216
    local r = math.floor(total / 65536) % 256
    local g = math.floor(total / 256) % 256
    local b = total % 256
    tex:SetColorTexture(r / 255, g / 255, b / 255, 1)
end

local function TotalCasts()
    local sum = 0
    for _, n in pairs(P13TweaksDB.skillCounts or {}) do sum = sum + n end
    return sum
end

local function UpdateBeacon()
    if ns:Get("skillBeacon") then
        SetBeacon(TotalCasts())
        beacon:Show()
    else
        beacon:Hide()
    end
end

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

local function Record(name)
    P13TweaksDB.skillCounts = P13TweaksDB.skillCounts or {}
    P13TweaksDB.skillCounts[name] = (P13TweaksDB.skillCounts[name] or 0) + 1
    local log = P13TweaksDB.skillHistory
    if not log then log = {}; P13TweaksDB.skillHistory = log end
    table.insert(log, { time(), name })
    while #log > MAX_LOG do table.remove(log, 1) end
    if ns:Get("skillBeacon") then SetBeacon(TotalCasts()) end
end

local function Update()
    ReadNames()
    UpdateBeacon()
end

ns:RegisterOption({
    key = "skillLog",
    type = "toggleText",
    label = "Log skill use",
    before = "Log use of:",
    inputKey = "skillLogNames",
    inputDefault = DEFAULT_SPELLS,
    boxWidth = 140,
    maxLetters = 60,
    tooltip = "Counts every time you cast these skills (names as in your spellbook, separated by commas) and keeps a log with times in the saved variables file (written on /reload or logout). /p13 skills shows the totals.",
    default = true,
    onChange = Update,
})

ns:RegisterOption({
    key = "skillBeacon",
    type = "toggle",
    label = "Skill-use beacon (for outside software)",
    tooltip = "Shows a small square in the top-left corner of the screen. Its colour encodes the total number of logged casts (red x 65536 + green x 256 + blue) and changes on every cast, so a program watching that screen pixel can detect each use. Needs the game in windowed or borderless mode.",
    default = false,
    onChange = Update,
})

ns:RegisterCommand("skills", "show logged skill-use totals", function()
    local counts = P13TweaksDB.skillCounts
    if not counts or not next(counts) then ns:Print("No skill use logged yet."); return end
    for name, n in pairs(counts) do ns:Print("  " .. name .. ": " .. n) end
    ns:Print("Total: " .. TotalCasts() .. " (beacon value)")
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:SetScript("OnEvent", function(self, event, unit, _, spellID)
    if event == "PLAYER_LOGIN" then
        Update()
        return
    end
    if unit ~= "player" or not ns:Get("skillLog") then return end
    if IsSecret(spellID) or not spellID then return end
    local name = SpellName(spellID)
    local shown = name and tracked[name:lower()]
    if shown then Record(shown) end
end)

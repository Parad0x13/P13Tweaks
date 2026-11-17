-- P13Tweaks feature: play a pleasant chime when a spell (default "Skysight") comes off cooldown.
-- The spell is typed into the options window by name; several can be given, separated by commas.
-- Works for items too (by name), as long as the item is in your bags.
-- How: whenever cooldowns change we look up when each tracked spell will be ready and set a
-- timer for that moment. The global cooldown (1.5 s or less) is ignored, so casting other spells
-- never sets it off. Spells that are already ready when you log in don't chime.
local ADDON_NAME, ns = ...

local DEFAULT_SPELLS = "Skysight"
local GCD = 1.5                -- cooldowns this short are the global cooldown, not the spell's own

-- A single bell "ding" (the auction house bell).
local SOUND = (SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_OPEN) or 5274

local function Chime()
    PlaySound(SOUND, "Master")
end

-- Typed text -> list of names ("Skysight, Blink" -> { "Skysight", "Blink" }).
local tracked = {}
local function ReadNames()
    wipe(tracked)
    for name in (ns:Get("spellReadyNames") or ""):gmatch("[^,]+") do
        name = strtrim(name)
        if name ~= "" then table.insert(tracked, name) end
    end
end

-- Returns start, duration, enabled for a spell (or item) name, or nil if we can't find it.
local function GetCooldown(name)
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, name)
        if ok and info then return info.startTime, info.duration, info.isEnabled end
    elseif GetSpellCooldown then
        local ok, s, d, e = pcall(GetSpellCooldown, name)
        if ok and s then return s, d, e ~= 0 and e ~= false end
    end
    -- Not a spell you know: try an item with that name.
    local link = GetItemInfo and select(2, GetItemInfo(name))
    local id = link and tonumber(link:match("item:(%d+)"))
    if id then
        local getItemCd = (C_Container and C_Container.GetItemCooldown) or _G.GetItemCooldown
        if getItemCd then
            local s, d, e = getItemCd(id)
            if s then return s, d, e ~= 0 and e ~= false end
        end
    end
    return nil
end

-- Seconds until ready (0 = ready now), "wait" = cooldown hasn't started yet (e.g. while its
-- buff is still up), or nil = spell not found.
local function Remaining(name)
    local s, d, enabled = GetCooldown(name)
    if not s then return nil end
    if not enabled then return "wait" end
    if d <= GCD or s == 0 then return 0 end
    return math.max(0, s + d - GetTime())
end

local cooling = {}     -- name -> true while we're waiting for it to come off cooldown
local timerToken = {}  -- name -> number; bumped so old timers know they're stale

local function Check(name, quiet)
    local r = Remaining(name)
    if r == nil then cooling[name] = nil; return end
    if r == "wait" or r > 0 then
        cooling[name] = true
        if r ~= "wait" then
            timerToken[name] = (timerToken[name] or 0) + 1
            local token = timerToken[name]
            C_Timer.After(r + 0.05, function()
                if timerToken[name] == token then Check(name) end
            end)
        end
    elseif cooling[name] then
        cooling[name] = nil
        timerToken[name] = (timerToken[name] or 0) + 1
        if not quiet and ns:Get("spellReady") then Chime() end
    end
end

local function CheckAll(quiet)
    for _, name in ipairs(tracked) do Check(name, quiet) end
end

local function Update()
    wipe(cooling)
    ReadNames()
    CheckAll(true)   -- learn what's cooling down now, without chiming
end

ns:RegisterOption({
    key = "spellReady",
    type = "toggleText",
    label = "Chime when a spell is ready",
    before = "Chime when ready:",
    inputKey = "spellReadyNames",
    inputDefault = DEFAULT_SPELLS,
    boxWidth = 140,
    maxLetters = 60,
    tooltip = "Plays a ding the moment this spell comes off cooldown. Type the spell's name exactly as in your spellbook. For more than one, separate them with commas (e.g. Skysight, Blink). Item names work too.\n\nThe global cooldown is ignored. /p13 ready plays the ding and shows each spell's cooldown.",
    default = true,
    onChange = Update,
})

ns:RegisterCommand("ready", "play the spell-ready ding and show cooldowns", function()
    Chime()
    ns:Print("Played the spell-ready ding." .. (ns:Get("spellReady") and "" or " (The option is OFF in /p13.)"))
    if #tracked == 0 then ns:Print("No spells typed in /p13."); return end
    for _, name in ipairs(tracked) do
        local r = Remaining(name)
        local state = r == nil and "|cffff4040not found - check the spelling (must be in your spellbook or bags)|r"
            or r == "wait" and "cooldown starts when its effect ends"
            or r > 0 and ("ready in %d s"):format(math.ceil(r))
            or "ready"
        ns:Print("  " .. name .. ": " .. state)
    end
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
frame:RegisterEvent("BAG_UPDATE_COOLDOWN")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        P13TweaksDB.spellReadySound = nil   -- removed sound picker
        Update()
    else
        -- (a spell only chimes after we've seen it cooling down, so newly learned spells don't)
        CheckAll(false)
    end
end)

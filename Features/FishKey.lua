-- P13Tweaks feature: one key for fishing.
--   Press it        -> casts Fishing.
--   Press it again  -> while the line is out, it's "Interact with Target", which reels in the
--                      bobber (the game's soft-target interact picks the bobber for you).
-- Done with a temporary override binding, so your normal keybinds are never changed; turning
-- the option off gives the key back. Bindings can't change in combat, so a swap that's due
-- then waits until combat ends.
local ADDON_NAME, ns = ...

local DEFAULT_KEY = "`"                 -- the tilde key (WoW calls it "`")
local FISHING_IDS = { 131474, 7620 }    -- Fishing (modern ID, then the classic rank 1 ID)
local SWAP_BACK_DELAY = 0.5             -- after reeling in: so the same key press can't recast

local owner = CreateFrame("Frame")

-- Secure button the key "clicks" to cast. Registered for key-down or key-up to match the game
-- setting, never both (both would cast twice on one press).
local btn = CreateFrame("Button", "P13TweaksFishButton", UIParent, "SecureActionButtonTemplate")
btn:SetAttribute("type", "macro")
btn:Hide()

local function FishingName()
    for _, id in ipairs(FISHING_IDS) do
        local n = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id))
            or (GetSpellInfo and (GetSpellInfo(id)))
        if n then return n end
    end
    return "Fishing"
end

local reeling = false     -- true while the line is out
local pending = false     -- a binding change is waiting for combat to end
local savedSoft           -- SoftTargetInteract value to put back after reeling

local function RestoreSoft()
    if savedSoft ~= nil then
        SetCVar("SoftTargetInteract", savedSoft)
        savedSoft = nil
    end
end

local function Apply()
    if InCombatLockdown() then pending = true; return end
    pending = false
    ClearOverrideBindings(owner)

    local key = strtrim(ns:Get("fishKey") or "")
    if not ns:Get("fishKeyOn") or key == "" then RestoreSoft(); return end

    if reeling then
        -- Soft-target interact is what lets "Interact with Target" find the bobber.
        local soft = GetCVar("SoftTargetInteract")
        if soft == "0" and savedSoft == nil then
            savedSoft = soft
            SetCVar("SoftTargetInteract", "3")
        end
        SetOverrideBinding(owner, true, key, "INTERACTTARGET")
    else
        RestoreSoft()
        btn:RegisterForClicks(GetCVarBool("ActionButtonUseKeyDown") and "AnyDown" or "AnyUp")
        btn:SetAttribute("macrotext", "/cast " .. FishingName())
        SetOverrideBindingClick(owner, true, key, btn:GetName(), "LeftButton")
    end
end

local function IsFishing(spellID)
    local n = spellID and ((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
        or (GetSpellInfo and (GetSpellInfo(spellID))))
    return n ~= nil and n == FishingName()
end

---------------------------------------------------------------------------
-- Louder splash: while the line is out, sound effects go to full and music/ambience are
-- muted so the bobber's splash stands out; sound also keeps playing when WoW isn't the
-- active window. Your settings are saved first (in P13TweaksDB, so a /reload or disconnect
-- mid-cast still gets them back at next login) and put back shortly after you reel in.
---------------------------------------------------------------------------
-- Sound_SFXVolume (the splash's volume) comes from the slider in /p13 (fishLoudSfx, %).
local DEFAULT_SFX_PCT = 100
local function SfxValue() return tostring((ns:Get("fishLoudSfx") or DEFAULT_SFX_PCT) / 100) end

local LOUD = {
    Sound_EnableSFX = "1",
    Sound_SFXVolume = SfxValue,
    Sound_MusicVolume = "0",
    Sound_AmbienceVolume = "0",
    Sound_EnableSoundWhenGameIsInBG = "1",
}
local LOUD_RESTORE_DELAY = 3   -- seconds; recasting within this keeps the loud settings

local function SoundOn()
    if not ns:Get("fishLoud") or P13TweaksDB.fishSavedSound then return end
    local saved = {}
    for cvar, value in pairs(LOUD) do
        local old = GetCVar(cvar)
        if old ~= nil then
            saved[cvar] = old
            SetCVar(cvar, type(value) == "function" and value() or value)
        end
    end
    P13TweaksDB.fishSavedSound = saved
end

local function SoundOff()
    local saved = P13TweaksDB and P13TweaksDB.fishSavedSound
    if not saved then return end
    for cvar, old in pairs(saved) do SetCVar(cvar, old) end
    P13TweaksDB.fishSavedSound = nil
end

local swapToken = 0
owner:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        if IsFishing(spellID) then
            swapToken = swapToken + 1
            reeling = true
            Apply()
            SoundOn()
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if reeling then
            swapToken = swapToken + 1
            local token = swapToken
            C_Timer.After(SWAP_BACK_DELAY, function()
                if token ~= swapToken then return end
                reeling = false
                Apply()
            end)
            C_Timer.After(LOUD_RESTORE_DELAY, function()
                if token == swapToken and not reeling then SoundOff() end
            end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pending then Apply() end
    else -- PLAYER_LOGIN
        SoundOff()   -- left over from a /reload or disconnect while fishing
        Apply()
    end
end)
owner:RegisterEvent("PLAYER_LOGIN")
owner:RegisterEvent("PLAYER_REGEN_ENABLED")
owner:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
owner:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")

ns:RegisterOption({
    key = "fishKeyOn",
    type = "toggleText",
    label = "One key fishing (cast, then reel in)",
    before = "One key fishing (cast + reel in), key:",
    inputKey = "fishKey",
    inputDefault = DEFAULT_KEY,
    boxWidth = 70,
    upper = true,
    tooltip = "Press the key to cast Fishing. While your line is out the same key reels it in (it becomes \"Interact with Target\", which picks the bobber for you). Your normal keybinds aren't changed - turning this off gives the key back.\n\nType the key the way WoW names keys: ` for the tilde key, F, SHIFT-F, CTRL-1, BUTTON4 (mouse)... Press Enter to save.",
    default = true,
    onChange = function() Apply() end,
})

ns:RegisterOption({
    key = "fishLoud",
    type = "toggleSlider",
    label = "Louder splash while fishing",
    before = "Louder splash while fishing",
    numberKey = "fishLoudSfx",
    numberDefault = DEFAULT_SFX_PCT,
    min = 0, max = 100, step = 5,
    tooltip = "While your line is out: the game's Sound Effects volume is set to the slider's % (the splash is a sound effect), music and ambient sound are muted, and sound keeps playing when WoW isn't the active window. Master volume isn't touched. Your own sound settings come back a few seconds after you stop fishing.\n\nDrag the slider while your line is out to hear the difference straight away.",
    default = true,
    onChange = function(v)
        if v == false then
            SoundOff()
        elseif type(v) == "number" and P13TweaksDB.fishSavedSound then
            SetCVar("Sound_SFXVolume", SfxValue())   -- fishing right now: apply live
        end
    end,
})

ns:RegisterCommand("fish", "show what the fishing key is doing right now", function()
    local key = strtrim(ns:Get("fishKey") or "")
    if not ns:Get("fishKeyOn") then ns:Print("One key fishing is OFF (/p13 to turn it on)."); return end
    ns:Print(("Fishing key %s: %s%s. Soft-target interact: %s. Spell: %s.")
        :format(key ~= "" and key or "(none)", reeling and "reel in (Interact with Target)" or "cast Fishing",
            pending and " |cffffd200(change waiting for combat to end)|r" or "",
            tostring(GetCVar("SoftTargetInteract")), FishingName()))
end)

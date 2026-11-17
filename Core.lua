-- P13Tweaks: core (saved settings, option registry, slash commands)
local ADDON_NAME, ns = ...

ns.name = "P13Tweaks"
-- Version from the .toc ("## Version:"). It's bumped on every update so you and a friend can compare.
-- Version.lua (loaded first) sets ns.version; the .toc value is only a fallback.
ns.version = ns.version or (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")) or "?"
ns.options = {}   -- ordered list of option definitions

-- Print a message with the addon's colored prefix.
function ns:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ns.name .. "|r: " .. tostring(msg))
end

-- Register an option. Feature files call this to show up in the options window.
--   key      unique saved-variable key
--   type     "toggle", "toggleNumber", "text" or "info" (see Options.lua)
--   label    text shown in the window (tooltip title for toggleNumber)
--   tooltip  optional hover text
--   default  default value
--   onChange optional function(value) called when the user changes it
--   numberKey / numberDefault  toggleNumber / toggleSlider: the second saved value
--   inputKey / inputDefault    toggleText only: the second saved value
--            (changing either also calls onChange)
function ns:RegisterOption(def)
    assert(def.key and def.type and def.label, "option needs key, type and label")
    table.insert(self.options, def)
end

function ns:Get(key)
    return P13TweaksDB[key]
end

function ns:Set(key, value)
    P13TweaksDB[key] = value
    for _, def in ipairs(self.options) do
        if (def.key == key or def.numberKey == key or def.inputKey == key) and def.onChange then
            def.onChange(value)
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if arg1 == ADDON_NAME then
        P13TweaksDB = P13TweaksDB or {}
        P13TweaksDB.welcomeMessage, P13TweaksDB.mapExtraZoom = nil, nil  -- removed options
        P13TweaksDB.herbArrow, P13TweaksDB.herbArrowPos, P13TweaksDB.herbs = nil, nil, nil  -- removed herb arrow
        P13TweaksDB.targetMarker, P13TweaksDB.targetMarkerIcon = nil, nil  -- removed target arrow
        P13TweaksDB.priorityTarget, P13TweaksDB.priorityTargetQuestInfo = nil, nil  -- removed quest target key
        P13TweaksDB.priorityTargetNames, P13TweaksDB.priorityTargetQuests = nil, nil
        P13TweaksDB.tileTestLog, P13TweaksDB.flightDebugLog, P13TweaksDB.taxiDebug = nil, nil, nil  -- removed test/debug logs
        P13TweaksDB.mapDragLog = nil
        P13TweaksDB.questShareButton = nil  -- removed quest-log button
        P13TweaksDB.mapCenterButton, P13TweaksDB.mapCenterKey = nil, nil  -- removed map Center button (middle-click does it)
        -- removed map Overlay feature: if a /reload left the game's "fade map while moving" setting off, put it back
        if P13TweaksDB.mapOverlaySavedFade then pcall(SetCVar, "mapFade", P13TweaksDB.mapOverlaySavedFade) end
        P13TweaksDB.mapOverlay, P13TweaksDB.mapOverlayAlpha, P13TweaksDB.mapOverlayAlpha20 = nil, nil, nil
        P13TweaksDB.mapOverlaySavedFade = nil
        P13TweaksDB.fishMap, P13TweaksDB.fishMapView, P13TweaksDB.fishLog = nil, nil, nil  -- removed fishing map
        for _, def in ipairs(ns.options) do
            if P13TweaksDB[def.key] == nil then
                P13TweaksDB[def.key] = def.default
            end
            if def.numberKey and P13TweaksDB[def.numberKey] == nil then
                P13TweaksDB[def.numberKey] = def.numberDefault
            end
            if def.inputKey and P13TweaksDB[def.inputKey] == nil then
                P13TweaksDB[def.inputKey] = def.inputDefault
            end
        end
        ns:CreateOptionsUI()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- Small buttons in a row along the bottom-left of the world map picture. Features add theirs
-- with ns:AddMapButton(button, order); shown ones are laid out left to right by `order`.
ns.mapButtons = {}

function ns.LayoutMapButtons()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc then return end
    local x = 6
    for _, b in ipairs(ns.mapButtons) do
        b:ClearAllPoints()
        if b:IsShown() then
            b:SetPoint("BOTTOMLEFT", sc, "BOTTOMLEFT", x, 6)
            x = x + b:GetWidth() + 4
        end
    end
end

function ns:AddMapButton(button, order)
    button.p13Order = order or 0
    table.insert(self.mapButtons, button)
    table.sort(self.mapButtons, function(a, b) return a.p13Order < b.p13Order end)
    -- re-lay the row whenever a button is shown or hidden
    hooksecurefunc(button, "Show", ns.LayoutMapButtons)
    hooksecurefunc(button, "Hide", ns.LayoutMapButtons)
    hooksecurefunc(button, "SetShown", ns.LayoutMapButtons)
    ns.LayoutMapButtons()
end

-- Extra "/p13 <word>" commands that features can add. Plain /p13 opens the options.
ns.commands = {}
function ns:RegisterCommand(word, help, func)
    self.commands[word:lower()] = { help = help, func = func }
end

SLASH_P13TWEAKS1 = "/p13"
SLASH_P13TWEAKS2 = "/p13tweaks"
SlashCmdList["P13TWEAKS"] = function(msg)
    local word, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    word = (word or ""):lower()
    if word == "" then
        ns:ToggleOptions()
    elseif ns.commands[word] then
        ns.commands[word].func(rest)
    else
        ns:Print("commands: /p13 (options)")
        for w, c in pairs(ns.commands) do ns:Print("  /p13 " .. w .. " - " .. c.help) end
    end
end

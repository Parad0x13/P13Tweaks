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

-- Per-frame "has anything changed?" check without building a string (a signature string made every
-- frame by several map layers was a steady stream of garbage). `store` is a table the caller keeps;
-- returns true when every value equals what the last call stored. Pass numbers pre-rounded
-- (math.floor(x * 1e5)) where tiny differences should not count.
function ns.SigSame(store, ...)
    local n = select("#", ...)
    local same = store.n == n
    for i = 1, n do
        local v = select(i, ...)
        if store[i] ~= v then same = false; store[i] = v end
    end
    store.n = n
    return same
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
        P13TweaksDB.cookingProfit, P13TweaksDB.cookRecipes, P13TweaksDB.cookDebug = nil, nil, nil  -- removed cooking profit (moved to TSM)
        P13TweaksDB.pinLog, P13TweaksDB.pinMethods = nil, nil  -- removed arrow-flicker diagnostics (bug solved)
        P13TweaksDB.mapTerrainTrim, P13TweaksDB.hiddenTiles, P13TweaksDB.mapDebugTiles = nil, nil, nil  -- removed tile heuristics (data now comes from the client)
        P13TweaksDB.mapRegions = nil
        P13TweaksDB.mapQuestMax = nil  -- removed: quest log on the maximized map
        P13TweaksDB.mapTerrainSeeThrough = nil  -- removed see-through tiles (the tile pictures have no transparency)
        -- One-time: show EVERY terrain tile exactly as the client draws it, so the new tile data can be checked
        -- (nothing see-through, blue sea behind so tile edges show, full opacity). Each can be switched back in
        -- /p13 > Map > Look afterwards.
        if not P13TweaksDB.terrainReviewV1 then
            P13TweaksDB.terrainReviewV1 = true
            P13TweaksDB.mapTerrain = true
            P13TweaksDB.mapTerrainBlackSea = false
            P13TweaksDB.mapTerrainAlpha = 100
        end
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

-- How far up the row must sit to clear things another addon lays along the bottom of the map (e.g. a
-- "Player: x, y   Cursor: x, y" coordinates strip, which covered our buttons). Looks for any shown, low
-- frame on the map window or its map area that overlaps the bottom-left stretch where our row goes and
-- isn't ours - also the game's own coordinate texts (Leatrix Maps moves them into the map's bottom edge
-- as narrow frames of their own, which the old "wide bar only" test skipped).
local function BottomBarClearance(sc)
    local scL, scB, scR = sc:GetLeft(), sc:GetBottom(), sc:GetRight()
    if not (scL and scB and scR) then return 0 end
    local ours, rowW = {}, 0
    for _, b in ipairs(ns.mapButtons) do
        ours[b] = true
        if b:IsShown() then rowW = rowW + (b:GetWidth() or 0) + 4 end
    end
    if rowW == 0 then return 0 end
    local lift = 0
    local function One(c)
        if c and c ~= sc and not ours[c] and c ~= WorldMapFrame.BorderFrame and c.IsShown and c:IsShown()
            and c:IsVisible() then
            local l, r, b, t = c:GetLeft(), c:GetRight(), c:GetBottom(), c:GetTop()
            if l and r and b and t then
                -- (scale differences: compare in the map area's units)
                local k = c:GetEffectiveScale() / sc:GetEffectiveScale()
                l, r, b, t = l * k, r * k, b * k, t * k
                if (t - b) < 60 and l < scL + 6 + rowW and r > scL and b < scB + 10 and t > scB then
                    lift = math.max(lift, t - scB)
                end
            end
        end
    end
    local function Check(...)
        for i = 1, select("#", ...) do pcall(One, (select(i, ...))) end
    end
    Check(WorldMapFrame:GetChildren())
    Check(sc:GetChildren())
    if WorldMapFrame.BorderFrame then Check(WorldMapFrame.BorderFrame:GetChildren()) end
    for _, o in ipairs(WorldMapFrame.overlayFrames or {}) do
        if o.PlayerCoords then Check(o.PlayerCoords, o.CursorCoords, o.CrosshairCoords) end
    end
    ns.mapButtonLift = lift   -- (for debugging)
    return lift
end

function ns.LayoutMapButtons()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc then return end
    local x, y = 6, 6 + BottomBarClearance(sc)
    for _, b in ipairs(ns.mapButtons) do
        b:ClearAllPoints()
        if b:IsShown() then
            b:SetPoint("BOTTOMLEFT", sc, "BOTTOMLEFT", x, y)
            x = x + b:GetWidth() + 4
        end
    end
end
-- the other addon's bar may only appear (or move) once the map is open: lay the row again then
do
    local hooked
    local function Hook()
        if hooked or not WorldMapFrame then return end
        hooked = true
        WorldMapFrame:HookScript("OnShow", function()
            C_Timer.After(0, ns.LayoutMapButtons)
            C_Timer.After(0.5, ns.LayoutMapButtons)
        end)
        WorldMapFrame:HookScript("OnSizeChanged", function() C_Timer.After(0, ns.LayoutMapButtons) end)
    end
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_LOGIN")
    ev:SetScript("OnEvent", Hook)
end

-- Icon layers on the world map (flight points, town icons, quest hints, route) place themselves from their
-- own OnUpdate, whose order against the map's is not fixed: right after we change the zoom or the map level
-- they would be drawn for one frame at the OLD scale (one giant icon = a flicker). Each layer registers its
-- placement function here; the map code calls ns.RefreshMapLayers() in the same frame as the change.
local layerRefreshers = {}
function ns.AddMapLayerRefresh(fn) layerRefreshers[#layerRefreshers + 1] = fn end
function ns.RefreshMapLayers()
    ns.layersStamp = GetTime()   -- (a layer's own per-frame check can skip itself if this already ran this frame)
    for i = 1, #layerRefreshers do pcall(layerRefreshers[i]) end
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

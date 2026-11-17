-- P13Tweaks feature: the world map as a see-through overlay while you play.
-- The map's Overlay button makes the open map partly transparent and click-through (mouse
-- and wheel go to the game), zooms in on you and keeps following you like a big minimap.
-- Pressing the map key (M) turns the overlay off and shows the normal map in one press;
-- Escape just closes it.
local ADDON_NAME, ns = ...

-- (all file-level locals up here, before any function uses them)
local active = false
local justEnded = false
local disabled = {}       -- frame -> { m = true, w = true }: mouse / wheel we switched off
local savedAlpha
local savedMapFade        -- the game's "fade map while moving" setting, put back afterwards
local settingAlpha = false
local button

local function Alpha()
    local pct = tonumber(ns:Get("mapOverlayAlpha")) or 20
    return math.max(5, math.min(100, pct)) / 100
end

-- Switch off mouse and wheel on the map and everything in it (pins come and go, so this runs
-- again every half second while the overlay is on). Protected frames are left alone.
local function MouseOff(f)
    if f.IsMouseEnabled and not (f.IsProtected and f:IsProtected()) then
        if f:IsMouseEnabled() then
            f:EnableMouse(false)
            disabled[f] = disabled[f] or {}
            disabled[f].m = true
        end
        if f.IsMouseWheelEnabled and f:IsMouseWheelEnabled() then
            f:EnableMouseWheel(false)
            disabled[f] = disabled[f] or {}
            disabled[f].w = true
        end
    end
    for _, c in ipairs({ f:GetChildren() }) do MouseOff(c) end
end

local function MouseBack()
    for f, s in pairs(disabled) do
        if not (f.IsProtected and f:IsProtected()) then
            if s.m then f:EnableMouse(true) end
            if s.w then f:EnableMouseWheel(true) end
        end
    end
    wipe(disabled)
end

local function SetButtonsAlpha(a)
    for _, b in ipairs(ns.mapButtons or {}) do b:SetAlpha(a) end
end

-- Everything around the map picture - quest log panel, title bar, border, the round buttons -
-- made invisible while overlaid (alpha 0, not hidden, so the game's own logic isn't disturbed).
-- Re-applied every half second, as the game may show parts again.
local chrome = {}   -- frame or texture -> its alpha before
local function HideChrome()
    local sc = WorldMapFrame.ScrollContainer
    -- never fade the map itself, or a frame that holds it
    local holders = {}
    local p = sc
    while p do holders[p] = true; p = p:GetParent() end
    local function Fade(obj)
        -- (the minimap may be borrowed for Cave view - keep it visible)
        if obj and obj.SetAlpha and not holders[obj] and obj ~= sc.Child and obj ~= Minimap then
            if chrome[obj] == nil then chrome[obj] = obj:GetAlpha() end
            if obj:GetAlpha() ~= 0 then obj:SetAlpha(0) end
        end
    end
    -- the siblings at every level from the map up to the map window
    local h = sc
    while h do
        for _, c in ipairs({ h:GetChildren() }) do Fade(c) end
        if h ~= sc then
            for _, r in ipairs({ h:GetRegions() }) do Fade(r) end
        end
        if h == WorldMapFrame then break end
        h = h:GetParent()
    end
    for _, name in ipairs({ "QuestMapFrame", "WorldMapQuestLog" }) do   -- if parented elsewhere
        Fade(_G[name])
    end
end

local function ShowChrome()
    for obj, a in pairs(chrome) do obj:SetAlpha(a) end
    wipe(chrome)
end

-- Move the map window so the map PICTURE is in the middle of the screen (the window's other,
-- now invisible, parts are off to one side). Its original anchors are put back afterwards.
local savedPoints     -- { size = {w, h}, points = { {point, rel, relPoint, x, y}, ... } }
local function CanMove()
    return not (InCombatLockdown() and WorldMapFrame:IsProtected())
end

local function CentreMap()
    if not CanMove() then return end
    local sc = WorldMapFrame.ScrollContainer
    local sx, sy = sc:GetCenter()
    local ux, uy = UIParent:GetCenter()
    local l, t = WorldMapFrame:GetLeft(), WorldMapFrame:GetTop()
    if not (sx and ux and l) then return end
    local ss, us, fs = sc:GetEffectiveScale(), UIParent:GetEffectiveScale(), WorldMapFrame:GetEffectiveScale()
    local dx, dy = ux * us - sx * ss, uy * us - sy * ss     -- screen pixels to move
    if math.abs(dx) < 1 and math.abs(dy) < 1 then return end
    if not savedPoints then
        savedPoints = { size = { WorldMapFrame:GetSize() }, points = {} }
        for i = 1, WorldMapFrame:GetNumPoints() do
            table.insert(savedPoints.points, { WorldMapFrame:GetPoint(i) })
        end
    end
    local w, h = WorldMapFrame:GetSize()
    WorldMapFrame:ClearAllPoints()
    WorldMapFrame:SetSize(w, h)
    WorldMapFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l + dx / fs, t + dy / fs)
end

-- Scale the map window so the map picture is about the size of the screen.
local FILL = 0.96          -- share of the screen to fill (a little margin)
local savedScale
local function FillScreen()
    if not CanMove() then return end
    local sc = WorldMapFrame.ScrollContainer
    local w, h = sc:GetWidth(), sc:GetHeight()
    local uw, uh = UIParent:GetWidth(), UIParent:GetHeight()
    if not (w and w > 0 and h and h > 0 and uw and uh) then return end
    -- on-screen size of the picture right now, in UIParent units
    local k = sc:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local grow = math.min(uw * FILL / (w * k), uh * FILL / (h * k))
    if math.abs(grow - 1) < 0.01 then return end
    savedScale = savedScale or WorldMapFrame:GetScale()
    WorldMapFrame:SetScale(WorldMapFrame:GetScale() * grow)
end

local function UnfillScreen()
    if not savedScale or not CanMove() then return end
    WorldMapFrame:SetScale(savedScale)
    savedScale = nil
end

local function UncentreMap()
    if not savedPoints or not CanMove() then return end
    WorldMapFrame:ClearAllPoints()
    for _, p in ipairs(savedPoints.points) do WorldMapFrame:SetPoint(unpack(p)) end
    if #savedPoints.points < 2 then WorldMapFrame:SetSize(unpack(savedPoints.size)) end
    savedPoints = nil
end

local function SetMapAlpha(a)
    settingAlpha = true
    WorldMapFrame:SetAlpha(a)
    settingAlpha = false
end

local function Stop()
    if not active then return end
    active = false
    MouseBack()
    if savedMapFade ~= nil then
        pcall(SetCVar, "mapFade", savedMapFade)
        savedMapFade = nil
        P13TweaksDB.mapOverlaySavedFade = nil
    end
    SetMapAlpha(savedAlpha or 1)
    UnfillScreen()   -- scale back first: the saved anchors are in the old scale
    UncentreMap()
    ShowChrome()
    SetButtonsAlpha(1)
end

local function Start()
    if active or not WorldMapFrame:IsShown() then return end
    active = true
    savedAlpha = 1
    -- The game's own "fade the map while you move" would fight our opacity: off meanwhile.
    local fade = GetCVar and GetCVar("mapFade")
    if fade and fade ~= "0" then
        savedMapFade = fade
        P13TweaksDB.mapOverlaySavedFade = fade   -- so a /reload mid-overlay still gets it back
        pcall(SetCVar, "mapFade", "0")
    end
    SetMapAlpha(Alpha())
    SetButtonsAlpha(0)
    HideChrome()
    FillScreen()
    CentreMap()
    MouseOff(WorldMapFrame)
    if ns.CentreMapOnPlayer then ns.CentreMapOnPlayer(true) end
end

ns:RegisterOption({
    key = "mapOverlay",
    type = "toggleSlider",
    label = "Overlay button on the world map",
    before = "Overlay button on the map, opacity",
    numberKey = "mapOverlayAlpha",
    numberDefault = 20,
    min = 5, max = 100, step = 5,
    tooltip = "Adds an Overlay button to the world map: the map turns see-through (this opacity) and clicks go through it to the game, so you can play with it open. It zooms in on you and follows you. Press the map key (M) to get the normal map back, or Escape to close it.",
    default = true,
    onChange = function(v)
        if type(v) == "number" then
            if active then SetMapAlpha(Alpha()) end
        else
            if button then button:SetShown(v and true or false) end
            if not v then Stop() end
        end
    end,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    -- the default went from 60% to 20% opacity (user asked): move the old defaults over once
    if not P13TweaksDB.mapOverlayAlpha20 then
        P13TweaksDB.mapOverlayAlpha20 = true
        P13TweaksDB.mapOverlayAlpha10 = nil
        local a = P13TweaksDB.mapOverlayAlpha
        if a == 60 or a == 10 then P13TweaksDB.mapOverlayAlpha = 20 end
    end
    if P13TweaksDB.mapOverlaySavedFade then   -- left off by a /reload during the overlay
        pcall(SetCVar, "mapFade", P13TweaksDB.mapOverlaySavedFade)
        P13TweaksDB.mapOverlaySavedFade = nil
    end
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc then return end

    button = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    button:SetSize(70, 22)
    button:SetText("Overlay")
    button:SetFrameLevel(sc:GetFrameLevel() + 100)
    button:SetScript("OnClick", Start)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText("Map overlay")
        GameTooltip:AddLine("Turns the map see-through and lets clicks go through to the game, so you can play with it open. It follows you. Press M for the normal map again, Escape to close.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    button:SetShown(ns:Get("mapOverlay") and true or false)
    ns:AddMapButton(button, 40)

    -- Anything else changing the map's opacity while overlaid (the game fades it as you move):
    -- put ours straight back, in the same frame, so it never flickers.
    hooksecurefunc(WorldMapFrame, "SetAlpha", function(self, a)
        if active and not settingAlpha and math.abs((a or 1) - Alpha()) > 0.01 then
            SetMapAlpha(Alpha())
        end
    end)

    -- Map closed while overlaid: back to normal. If it was the map key (ToggleWorldMap),
    -- open it again straight away as the normal map.
    WorldMapFrame:HookScript("OnHide", function()
        if not active then return end
        Stop()
        justEnded = true
        C_Timer.After(0.2, function() justEnded = false end)
    end)
    if ToggleWorldMap then
        hooksecurefunc("ToggleWorldMap", function()
            if justEnded and not WorldMapFrame:IsShown() and not InCombatLockdown() then
                justEnded = false
                ToggleWorldMap()
            end
        end)
    end

    -- While overlaid: keep following you, keep new pins click-through, keep our opacity.
    local since = 0
    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function(_, elapsed)
        if not active then return end
        since = since + elapsed
        if since < 0.5 then return end
        since = 0
        HideChrome()
        FillScreen()
        CentreMap()   -- the game may move its panels about
        MouseOff(WorldMapFrame)
        if ns.CentreMapOnPlayer then ns.CentreMapOnPlayer(false) end
    end)
end)

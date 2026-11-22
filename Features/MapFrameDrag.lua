-- P13Tweaks feature: the Map & Quest Log window can be dragged around the screen (click and drag its title
-- bar - the map itself keeps its own drag, which pans / draws) and remembers where you put it.
-- The game's panel manager puts the window back at its fixed spot every time it opens (and whenever another
-- panel opens or closes), so we put it back at your spot right after each of those. Not while the map is
-- maximized (full screen) - then the game owns the placement.
local ADDON_NAME, ns = ...

local function Enabled() return ns:Get("mapFrameDrag") end
local function Maximized() return WorldMapFrame.IsMaximized and WorldMapFrame:IsMaximized() end

-- Put the window at the saved spot (top-left corner, in UIParent units).
local function Apply()
    local pos = P13TweaksDB.mapFramePos
    if not (Enabled() and pos and WorldMapFrame:IsShown() and not Maximized()) then return end
    WorldMapFrame:ClearAllPoints()
    WorldMapFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
end

local function Save()
    local l, t = WorldMapFrame:GetLeft(), WorldMapFrame:GetTop()
    if l and t then P13TweaksDB.mapFramePos = { x = l, y = t } end
end

ns:RegisterOption({
    key = "mapFrameDrag",
    type = "toggle",
    label = "Drag the map window by its title bar",
    tooltip = "Click and drag the Map & Quest Log window's title bar (the strip with its name, left of the buttons) to move it anywhere on the screen. It stays where you put it. (The map itself still pans and draws as before; maximized, the window is fixed.) /p13 mapframe reset puts it back.",
    default = true,
    onChange = function(on)
        if on then Apply() end
    end,
})

ns:RegisterCommand("mapframe", "map window position: /p13 mapframe reset", function(arg)
    if (arg or ""):lower():find("reset") then
        P13TweaksDB.mapFramePos = nil
        ns:Print("Map window position forgotten. It goes back to its normal spot the next time it opens.")
    else
        ns:Print("/p13 mapframe reset  - forget where you put the map window")
    end
end)

---------------------------------------------------------------------------
-- Hiding the window's decorative (gold) border
---------------------------------------------------------------------------

-- Hidden by setting transparency to 0 and keeping it there: the game sets it again when it rebuilds the
-- window, so the piece gets a hook that puts it back to 0 while we want it hidden.
local function Sticky(frame, hide)
    if not (frame and frame.SetAlpha) then return end
    if not frame.p13BorderHooked then
        frame.p13BorderHooked = true
        hooksecurefunc(frame, "SetAlpha", function(self, a)
            if self.p13BorderHidden and a ~= 0 then self:SetAlpha(0) end
        end)
    end
    frame.p13BorderHidden = hide
    frame:SetAlpha(hide and 0 or 1)
end

-- The border's pieces: the frame's NineSlice (edges and corners), and anything on the border frame with
-- "Border" in its name. Not the title, buttons, portrait or the background fill.
local function BorderPieces()
    local b = WorldMapFrame.BorderFrame
    local list, seen = {}, {}
    if not b then return list end
    local function Add(x) if x and not seen[x] and type(x) == "table" and x.SetAlpha then seen[x] = true; list[#list + 1] = x end end
    Add(b.NineSlice)
    for k, v in pairs(b) do
        if type(k) == "string" and k:find("Border") and not k:find("Close") and not k:find("Title") and not k:find("Portrait") then Add(v) end
    end
    return list
end

local warned
local function ApplyBorder()
    local hide = ns:Get("mapBorderHide") and Maximized() and true or false   -- (only while maximized)
    local pieces = BorderPieces()
    for _, p in ipairs(pieces) do Sticky(p, hide) end
    if hide and #pieces == 0 and not warned then   -- (only worth saying when it was wanted and nothing was found)
        warned = true
        ns:Print("Couldn't find the map window's border pieces to hide (this client names them differently).")
    end
end

ns:RegisterOption({
    key = "mapBorderHide",
    type = "toggle",
    label = "Hide the map window's gold border when maximized",
    tooltip = "When the map window is maximized, hides the decorative border around it (its title, buttons and background stay). The normal-sized window keeps its border.",
    default = false,
    onChange = function() ApplyBorder() end,
})

---------------------------------------------------------------------------
-- Maximized map as wide as the screen
---------------------------------------------------------------------------

local widened   -- { from = width before, to = width we set } while we have the window stretched

local function ApplyWidth()
    local f = WorldMapFrame
    if not (f and f:IsShown()) then return end
    if Maximized() and ns:Get("mapFullWidth") then
        -- the screen's width in the window's own units
        local want = UIParent:GetWidth() * UIParent:GetEffectiveScale() / f:GetEffectiveScale()
        if math.abs(f:GetWidth() - want) > 0.5 then
            local top = f:GetTop()
            if not widened then widened = { from = f:GetWidth() } end
            widened.to = want
            f:SetWidth(want)
            if top then   -- flush with the left edge of the screen, same height as before
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 0, top)
            end
        end
    elseif widened then
        -- no longer maximized (or the option went off): if the game has not already put its own width back, do it
        if math.abs(f:GetWidth() - widened.to) < 1 then f:SetWidth(widened.from) end
        widened = nil
    end
end

ns:RegisterOption({
    key = "mapFullWidth",
    type = "toggle",
    label = "Maximized map as wide as the screen",
    tooltip = "When the map window is maximized, stretch it to the full width of the screen.",
    default = true,
    onChange = function() ApplyWidth() end,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local f = WorldMapFrame
    if not f then return end
    f:SetMovable(true)
    f:SetClampedToScreen(true)

    -- The handle: a strip of our own along the title bar. (Not the game's BorderFrame: it covers the whole
    -- window, and giving it the mouse blocked every click on the map.) It stops short of the right end so the
    -- window's own buttons (maximize, close) still work, and sits just above the frame art.
    local handle = CreateFrame("Frame", nil, f)
    handle:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    handle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -120, -4)
    handle:SetHeight(26)
    local border = f.BorderFrame
    handle:SetFrameLevel((border and border:GetFrameLevel() or f:GetFrameLevel()) + 1)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:HookScript("OnDragStart", function()
        if Enabled() and not Maximized() then f:StartMoving() end
    end)
    handle:HookScript("OnDragStop", function()
        f:StopMovingOrSizing()
        if Enabled() and not Maximized() then Save() end
    end)

    -- the panel manager re-places the window when it opens and when other panels come and go
    -- (the width runs after the game has sized the window, so a frame later)
    local function Place() Apply(); ApplyWidth(); ApplyBorder() end
    f:HookScript("OnShow", function() C_Timer.After(0, Place); ApplyBorder() end)
    ApplyBorder()
    if UpdateUIPanelPositions then hooksecurefunc("UpdateUIPanelPositions", Place) end
    if f.SynchronizeDisplayState then hooksecurefunc(f, "SynchronizeDisplayState", function() C_Timer.After(0, Place) end) end
end)

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
-- Maximized map fills the whole screen
---------------------------------------------------------------------------

local widened   -- { from/fromH = size before, to/toH = size we set } while we have the window stretched
local applying  -- true while we resize it ourselves (so our own size-change hook ignores it)

-- Why it did not always stick: the game sizes the maximized window again on its own (when it opens
-- maximized, on maximize, on a resolution / UI scale change, when the panel manager re-places it), sometimes
-- AFTER our one-frame-later pass, and the map inside was never told the window got wider. Now: any size
-- change or re-placement while maximized is checked, the left edge is checked too (not only the width), and
-- the map is told to re-fit (the same call the game makes after it resizes the window).
local function ApplyWidth()
    local f = WorldMapFrame
    if applying or not (f and f:IsShown()) then return end
    if Maximized() and ns:Get("mapFullWidth") then
        -- the whole screen in the window's own units: width AND height (keeping the game's height and top
        -- left a strip of game showing above the title bar - the window sat too low, screenshot v0.30.29)
        local k = UIParent:GetEffectiveScale() / f:GetEffectiveScale()
        local screenW, screenH = UIParent:GetWidth() * k, UIParent:GetHeight() * k
        -- Maximized, the game keeps a title strip at the top of the window (TitleCanvasSpacerFrame, 67 units)
        -- whose title / border art is hidden, so its upper part is see-through: the game world showed above
        -- the map's button bar (measured with /p13 mapsize: window top 960, close button top 914). Push the
        -- window up by that empty part (off the top of the screen) so the button bar sits at the top edge.
        local gap = 0
        local close, ft = f.BorderFrame and f.BorderFrame.CloseButton, f:GetTop()
        if close and close:GetTop() and ft then
            local spacer = f.TitleCanvasSpacerFrame and f.TitleCanvasSpacerFrame:GetHeight() or 67
            gap = math.max(0, math.min(spacer, ft - close:GetTop() - 2))
        end
        local wantW, wantH = screenW, screenH + gap
        local left, top = f:GetLeft(), f:GetTop()
        local badSize = math.abs(f:GetWidth() - wantW) > 0.5 or math.abs(f:GetHeight() - wantH) > 0.5
        local badPlace = not (left and top) or math.abs(left) > 0.5 or math.abs(top - (screenH + gap)) > 0.5
        if badSize or badPlace then
            applying = true
            if not widened then widened = { from = f:GetWidth(), fromH = f:GetHeight() } end
            widened.to, widened.toH = wantW, wantH
            f:SetClampedToScreen(false)   -- (clamping would push it back down)
            f:SetSize(wantW, wantH)
            f:ClearAllPoints()   -- top-left corner of the screen, the empty strip above it
            f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, gap)
            if badSize and f.OnFrameSizeChanged then f:OnFrameSizeChanged() end   -- map re-fits the new size
            applying = false
        end
    elseif widened then
        -- no longer maximized (or the option went off): if the game has not already put its own width back, do it
        if math.abs(f:GetWidth() - widened.to) < 1 then f:SetWidth(widened.from) end
        if widened.toH and math.abs(f:GetHeight() - widened.toH) < 1 then f:SetHeight(widened.fromH) end
        f:SetClampedToScreen(true)
        widened = nil
    end
end

ns:RegisterOption({
    key = "mapFullWidth",
    type = "toggle",
    label = "Maximized map fills the whole screen",
    tooltip = "When the map window is maximized, stretch it to cover the whole screen - full width and full height, from the top-left corner.",
    default = true,
    onChange = function() ApplyWidth() end,
})

-- Diagnostic: writes the maximized window's real measurements into the saved file (chat can't be copied).
-- Read P13TweaksDB.mapSizeLog from SavedVariables after a /reload.
local function RecordSize(quiet)
    local f, sc = WorldMapFrame, WorldMapFrame and WorldMapFrame.ScrollContainer
    local function R(fr)
        if not fr then return "nil" end
        return ("L=%s R=%s T=%s B=%s W=%.1f H=%.1f scale=%.3f eff=%.3f shown=%s"):format(
            tostring(fr:GetLeft()), tostring(fr:GetRight()), tostring(fr:GetTop()), tostring(fr:GetBottom()),
            fr:GetWidth() or 0, fr:GetHeight() or 0, fr:GetScale() or 0, fr:GetEffectiveScale() or 0, tostring(fr:IsShown()))
    end
    local pts = {}
    for i = 1, f:GetNumPoints() do
        local p, rel, rp, x, y = f:GetPoint(i)
        pts[#pts + 1] = ("%s>%s.%s(%.1f,%.1f)"):format(p, rel and (rel:GetName() or "?") or "nil", rp, x or 0, y or 0)
    end
    local log = {
        time = date("%H:%M:%S"),
        maximized = tostring(Maximized()), fullWidth = tostring(ns:Get("mapFullWidth")),
        screen = GetPhysicalScreenSize and ("%sx%s"):format(tostring((GetPhysicalScreenSize())), tostring(select(2, GetPhysicalScreenSize()))) or "?",
        UIParent = R(UIParent), frame = R(f), points = table.concat(pts, " | "),
        parent = f:GetParent() and (f:GetParent():GetName() or "?") or "nil",
        scroll = R(sc), child = R(sc and sc.Child),
        canvasScale = sc and sc.GetCanvasScale and tostring(sc:GetCanvasScale()) or "nil",
        border = R(f.BorderFrame), widened = widened and ("%.1f -> %.1f"):format(widened.from or 0, widened.to or 0) or "nil",
        kids = {},
        buttonLift = tostring(ns.mapButtonLift),   -- how far our button row was raised above another addon's bar
    }
    -- every keyed child of the window and of its border frame: which one leaves the empty strip at the top
    local seen = {}
    local function Kids(owner, prefix)
        for k, v in pairs(owner) do
            if type(k) == "string" and type(v) == "table" and v.GetTop and v.GetObjectType and not seen[v] then
                seen[v] = true
                local ok, s = pcall(R, v)
                log.kids[#log.kids + 1] = prefix .. k .. " [" .. v:GetObjectType() .. "] " .. (ok and s or "?")
            end
        end
    end
    Kids(f, "")
    if f.BorderFrame then Kids(f.BorderFrame, "BorderFrame.") end
    table.sort(log.kids)
    P13TweaksDB.mapSizeLog = log
    if not quiet then ns:Print("Map size recorded - /reload so it gets saved.") end
end
ns:RegisterCommand("mapsize", "record the map window's size/position for debugging (saved on /reload)", function() RecordSize() end)

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
    -- TEMPORARY diagnostic (full-screen gap at the top): record the layout 1 s after the map is shown or
    -- switched to maximized. Remove once the gap is fixed.
    local function AutoRecord() C_Timer.After(1, function() if f:IsShown() and Maximized() then RecordSize(true) end end) end
    f:HookScript("OnShow", AutoRecord)
    if f.SynchronizeDisplayState then hooksecurefunc(f, "SynchronizeDisplayState", AutoRecord) end
    ApplyBorder()
    if UpdateUIPanelPositions then hooksecurefunc("UpdateUIPanelPositions", Place) end
    if f.SynchronizeDisplayState then hooksecurefunc(f, "SynchronizeDisplayState", function() C_Timer.After(0, Place) end) end
    -- the game resizing the maximized window itself (open, maximize, screen / UI scale change)
    if f.UpdateMaximizedSize then hooksecurefunc(f, "UpdateMaximizedSize", function() ApplyWidth(); C_Timer.After(0, ApplyWidth) end) end
    f:HookScript("OnSizeChanged", function()
        if not applying and Maximized() and ns:Get("mapFullWidth") then C_Timer.After(0, ApplyWidth) end
    end)
    loader:RegisterEvent("DISPLAY_SIZE_CHANGED")
    loader:RegisterEvent("UI_SCALE_CHANGED")
    loader:SetScript("OnEvent", function() C_Timer.After(0, ApplyWidth) end)
end)

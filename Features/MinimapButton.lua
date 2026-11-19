-- P13Tweaks feature: a round button on the minimap, showing the P13 glider-grid logo.
-- Left-click opens the options, right-click opens the teammates' quests window.
-- Drag it to move it around the edge of the minimap (the spot is remembered).
local ADDON_NAME, ns = ...

local DEFAULT_ANGLE = 215   -- degrees around the minimap, 0 = right, 90 = top
local btn

local function Angle() return ns:Get("minimapButtonAngle") or DEFAULT_ANGLE end

local function Place()
    local a = math.rad(Angle())
    local r = Minimap:GetWidth() / 2 + 5
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function FollowCursor()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local s = Minimap:GetEffectiveScale()
    px, py = px / s, py / s
    local atan = math.atan2 or math.atan
    ns:Set("minimapButtonAngle", math.deg(atan(py - my, px - mx)) % 360)
    Place()
end

local function Build()
    btn = CreateFrame("Button", "P13TweaksMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetClampedToScreen(true)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    -- same geometry the standard minimap buttons use: the ring art's hole sits at the top-left
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetVertexColor(0.051, 0.067, 0.09, 1)   -- #0d1117, the logo's background

    -- the Parad0x13 glider grid (Media/P13Icon.tga, made by tools/make_icon.py)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\P13Tweaks\\Media\\P13Icon.tga")
    icon:SetSize(15, 15)               -- 75% of the 20x20 disc
    icon:SetPoint("CENTER", bg, "CENTER", 0, 0)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints(btn)

    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            local c = ns.commands["quests"]
            if c then c.func() end
        else
            ns:ToggleOptions()
        end
    end)
    btn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", FollowCursor) end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(ns.name .. "  v" .. ns.version, 0.2, 1, 0.6)
        GameTooltip:AddLine("Left-click: options", 1, 1, 1)
        GameTooltip:AddLine("Right-click: teammates' quests", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    Place()
    btn:SetShown(ns:Get("minimapButton") and true or false)
end

ns:RegisterOption({
    key = "minimapButton",
    type = "toggle",
    label = "Show the P13 button on the minimap",
    tooltip = "A small round button on the minimap. Left-click opens these options, right-click opens your teammates' quests. Drag it to move it around the minimap.",
    default = true,
    onChange = function(on)
        if btn then btn:SetShown(on and true or false) end
    end,
})

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function() pcall(Build) end)

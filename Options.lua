-- P13Tweaks: options window (built from the option registry in Core.lua)
local ADDON_NAME, ns = ...

local WIDTH, PADDING = 380, 16

local function AddTooltip(widget, def)
    if not def.tooltip then return end
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(def.label, 1, 1, 1)
        GameTooltip:AddLine(def.tooltip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)
end

-- Each builder returns (control, heightUsed). control:Refresh() syncs it with saved settings.
local function CreateToggle(parent, def, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", PADDING, y)

    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(def.label)

    cb:SetScript("OnClick", function(self)
        ns:Set(def.key, self:GetChecked() and true or false)
    end)
    AddTooltip(cb, def)

    cb.Refresh = function(self) self:SetChecked(ns:Get(def.key)) end
    return cb, 28
end

local function CreateText(parent, def, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", PADDING + 6, y - 4)
    label:SetText(def.label)

    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(WIDTH - 2 * PADDING - 14, 20)
    eb:SetPoint("TOPLEFT", PADDING + 10, y - 20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(def.maxLetters or 500)

    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText(ns:Get(def.key) or "")   -- undo unsaved typing
        self:ClearFocus()
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        if self:GetText() ~= (ns:Get(def.key) or "") then ns:Set(def.key, self:GetText()) end
    end)
    AddTooltip(eb, def)

    eb.Refresh = function(self)
        if self:HasFocus() then return end  -- don't wipe what you're typing
        self:SetText(ns:Get(def.key) or "")
        self:SetCursorPosition(0)
    end
    return eb, 48
end

-- Read-only text that a feature fills in (def.getText), e.g. a live list.
local function CreateInfo(parent, def, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", PADDING + 10, y - 2)
    fs:SetWidth(WIDTH - 2 * PADDING - 14)
    fs:SetHeight(48)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    if fs.SetMaxLines then fs:SetMaxLines(4) end

    fs.Refresh = function(self)
        if not def.getText then return self:SetText("") end
        -- Never let one broken info line stop the rest of the window refreshing.
        local ok, text = pcall(def.getText)
        if ok then
            self:SetText(text or "")
        else
            self:SetText("|cffff5555Error: " .. tostring(text) .. "|r")
        end
    end
    return fs, 52
end

local builders = { toggle = CreateToggle, text = CreateText, info = CreateInfo }

function ns:CreateOptionsUI()
    -- Standalone movable window
    local f = CreateFrame("Frame", "P13TweaksOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()
    tinsert(UISpecialFrames, f:GetName()) -- Escape closes it

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText(ns.name .. " Options")

    local controls = {}
    local y = -36
    for _, def in ipairs(ns.options) do
        local build = builders[def.type]
        if build then
            local control, height = build(f, def, y)
            table.insert(controls, control)
            y = y - height
        end
    end
    f:SetSize(WIDTH, -y + 16)

    f.controls = controls
    f:SetScript("OnShow", function() ns:RefreshOptions() end)
    ns.optionsFrame = f

    -- Entry in the game's Options > AddOns list that opens the window
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local panel = CreateFrame("Frame")
        local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        header:SetPoint("TOPLEFT", 16, -16)
        header:SetText(ns.name)

        local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        btn:SetSize(160, 24)
        btn:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
        btn:SetText("Open " .. ns.name)
        btn:SetScript("OnClick", function()
            if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
            if GameMenuFrame and GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) end
            f:Show()
        end)

        local category = Settings.RegisterCanvasLayoutCategory(panel, ns.name)
        Settings.RegisterAddOnCategory(category)
    end
end

-- Re-sync every control with current settings (cheap; only does work while the window is open).
function ns:RefreshOptions()
    local f = ns.optionsFrame
    if not (f and f:IsShown()) then return end
    for _, c in ipairs(f.controls) do c:Refresh() end
end

function ns:ToggleOptions()
    local f = ns.optionsFrame
    if f then f:SetShown(not f:IsShown()) end
end

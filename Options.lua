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
    cb.label = label

    cb:SetScript("OnClick", function(self)
        ns:Set(def.key, self:GetChecked() and true or false)
    end)
    AddTooltip(cb, def)

    cb.Refresh = function(self) self:SetChecked(ns:Get(def.key)) end
    return cb, 28
end

-- Checkbox with a button after its label: "[x] Show running kill count [View...]".
--   def.buttonText, def.buttonWidth (default 70), def.onClick()
local function CreateToggleButton(parent, def, y)
    local cb, height = CreateToggle(parent, def, y)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(def.buttonWidth or 70, 20)
    b:SetPoint("LEFT", cb.label, "RIGHT", 8, 0)
    b:SetText(def.buttonText or "...")
    b:SetScript("OnClick", function() if def.onClick then def.onClick() end end)
    return cb, height
end

-- Checkbox with a small input box inside its label: "[x] Beep when target is within [30] yards".
--   def.before / def.after  text either side of the box (after is optional)
--   toggleNumber: def.numberKey  saved key for the number (def.key is the checkbox)
--                 def.snap(n)    optional: turns what was typed into the value to store
--   toggleText:   def.inputKey   saved key for the text; def.upper = save it in capitals
--   def.boxWidth  optional box width (default 30)
local function CreateToggleInput(parent, def, y, numeric)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", PADDING, y)
    cb:SetScript("OnClick", function(self)
        ns:Set(def.key, self:GetChecked() and true or false)
    end)
    AddTooltip(cb, def)

    local before = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    before:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    before:SetText(def.before)

    local valueKey = numeric and def.numberKey or def.inputKey
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(def.boxWidth or 30, 20)
    eb:SetPoint("LEFT", before, "RIGHT", 10, 0)   -- the template's border sticks out to the left
    eb:SetAutoFocus(false)
    eb:SetNumeric(numeric and true or false)
    eb:SetMaxLetters(def.maxLetters or (numeric and 3 or 20))
    eb:SetJustifyH("CENTER")
    AddTooltip(eb, def)

    if def.after then
        local after = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        after:SetPoint("LEFT", eb, "RIGHT", 4, 0)
        after:SetText(def.after)
    end

    local function show() eb:SetText(tostring(ns:Get(valueKey) or "")) end
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self)
        show()   -- undo unsaved typing
        self:ClearFocus()
    end)
    eb:SetScript("OnEditFocusLost", function()
        local v
        if numeric then
            v = tonumber(eb:GetText())
            if v and def.snap then v = def.snap(v) end
        else
            v = strtrim(eb:GetText() or "")
            if v == "" then v = nil elseif def.upper then v = v:upper() end
        end
        if v ~= nil and v ~= ns:Get(valueKey) then ns:Set(valueKey, v) end
        show()   -- also puts back the old value if the box was left empty
    end)

    cb.Refresh = function(self)
        self:SetChecked(ns:Get(def.key))
        if not eb:HasFocus() then show() end   -- don't wipe what you're typing
    end
    return cb, 28
end

-- Checkbox with a slider inside its label: "[x] Louder splash while fishing [===|=] 80%".
--   def.before            text before the slider
--   def.numberKey         saved key for the slider value (def.key is the checkbox)
--   def.min/max/step      slider range (default 0-100, step 5)
--   def.format            how the value is shown after the slider (default "%d%%")
--   def.sliderWidth       default 90
local function CreateToggleSlider(parent, def, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", PADDING, y)
    cb:SetScript("OnClick", function(self)
        ns:Set(def.key, self:GetChecked() and true or false)
    end)
    AddTooltip(cb, def)

    local before = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    before:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    before:SetText(def.before)

    local s = CreateFrame("Slider", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(def.sliderWidth or 90, 16)
    s:SetPoint("LEFT", before, "RIGHT", 10, 0)
    if s.SetBackdrop then
        s:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 3, right = 3, top = 6, bottom = 6 },
        })
    end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(def.min or 0, def.max or 100)
    s:SetValueStep(def.step or 5)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    AddTooltip(s, def)

    local valueText = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valueText:SetPoint("LEFT", s, "RIGHT", 6, 0)
    local fmt = def.format or "%d%%"

    local syncing = false   -- true while Refresh moves the slider, so that isn't saved as a change
    s:SetScript("OnValueChanged", function(_, v)
        local step = def.step or 5
        v = math.floor(v / step + 0.5) * step
        valueText:SetText(fmt:format(v))
        if not syncing and v ~= ns:Get(def.numberKey) then ns:Set(def.numberKey, v) end
    end)

    cb.Refresh = function(self)
        self:SetChecked(ns:Get(def.key))
        local v = ns:Get(def.numberKey) or def.numberDefault or 0
        syncing = true
        s:SetValue(v)
        syncing = false
        valueText:SetText(fmt:format(v))
    end
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

local builders = {
    toggle = CreateToggle,
    toggleNumber = function(parent, def, y) return CreateToggleInput(parent, def, y, true) end,
    toggleText = function(parent, def, y) return CreateToggleInput(parent, def, y, false) end,
    toggleSlider = CreateToggleSlider,
    toggleButton = CreateToggleButton,
    text = CreateText,
    info = CreateInfo,
}

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

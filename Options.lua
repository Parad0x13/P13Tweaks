-- P13Tweaks: options window (built from the option registry in Core.lua)
-- A sidebar of tabs on the left; each tab shows its options under section headings.
-- Where an option goes is set in LAYOUT below; an option that isn't listed there still
-- shows up, in an "Other" tab, so a new feature is never hidden.
local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Layout: tab -> sections -> option keys (in display order)
---------------------------------------------------------------------------

local LAYOUT = {
    { name = "Map", icon = "Interface\\Icons\\INV_Misc_Map_01", sections = {
        { "Zooming", { "mapSeamless", "mapZoomStep", "mapExtraZoomIn", "mapRemember" } },
        { "Finding yourself", { "mapPlayerCircle", "mapMiddleClick", "mapCenterButton", "mapSmoothPan" } },
        { "Look", { "mapTerrain", "mapTerrainLabels", "mapTerrainButton", "mapCaveView", "mapOverlay" } },
        { "Travel", { "mapRoute", "flightPoints", "flightPointsTaxi" } },
    } },
    { name = "Combat", icon = "Interface\\Icons\\Ability_DualWield", sections = {
        { "Aggro range", { "aggroRange", "aggroBeep" } },
        { "Target range", { "rangeBeep", "rangeDot" } },
        { "Levelling", { "killsToLevel", "killTally" } },
        { "Spells", { "spellReady" } },
    } },
    { name = "Quests", icon = "Interface\\Icons\\INV_Scroll_03", sections = {
        { "Quest enemies", { "questMobArrow" } },
        { "Group", { "questShare", "questShareTooltips" } },
    } },
    { name = "Towns", icon = "Interface\\Icons\\INV_Misc_Bag_10", sections = {
        { "Townsfolk", { "minimapTownsfolk", "worldmapTownsfolk" } },
        { "Portrait menu", { "classTrainerMenu" } },
    } },
    { name = "Professions", icon = "Interface\\Icons\\INV_Pick_02", sections = {
        { "Skill", { "profCap" } },
        { "Gathering", { "interactIcons" } },
        { "Fishing", { "fishKeyOn", "fishLoud" } },
    } },
    { name = "Chat & keys", icon = "Interface\\Icons\\INV_Letter_15", sections = {
        { "Chat", { "chatFade", "chatFadeShowNew", "chatScrollOne" } },
        { "Keybinds", { "freeKeysInfo" } },
    } },
}
local OTHER_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

---------------------------------------------------------------------------
-- Look
---------------------------------------------------------------------------

local SIDEBAR_W, CONTENT_W = 150, 470
local TITLE_H, FOOTER_H = 40, 26
local PADDING = 16               -- left margin of controls inside a tab
local ACCENT = { 0.2, 1, 0.6 }   -- same green as the chat prefix
local BG = { 0.06, 0.06, 0.08, 0.96 }
local SIDEBAR_BG = { 0.03, 0.03, 0.045, 0.9 }
local EDGE = { 0.28, 0.28, 0.34, 1 }

local function Fill(frame, c, layer)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

-- 1-pixel border on all four sides
local function Border(frame, c)
    local function Line(p1, p2, w, h)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        t:SetPoint(p1); t:SetPoint(p2)
        if w then t:SetWidth(w) else t:SetHeight(h) end
    end
    Line("TOPLEFT", "TOPRIGHT", nil, 1)
    Line("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Line("TOPLEFT", "BOTTOMLEFT", 1)
    Line("TOPRIGHT", "BOTTOMRIGHT", 1)
end

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

---------------------------------------------------------------------------
-- Controls. Each builder returns (control, heightUsed). control:Refresh() syncs it with
-- saved settings.
---------------------------------------------------------------------------

local function CreateToggle(parent, def, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
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
    return cb, 26
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
    cb:SetSize(26, 26)
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
    return cb, 26
end

-- Checkbox with a slider inside its label: "[x] Louder splash while fishing [===|=] 80%".
--   def.before            text before the slider
--   def.numberKey         saved key for the slider value (def.key is the checkbox)
--   def.min/max/step      slider range (default 0-100, step 5)
--   def.format            how the value is shown after the slider (default "%d%%")
--   def.sliderWidth       default 90
local function CreateToggleSlider(parent, def, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
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
    return cb, 26
end

-- Text box. A short one (maxLetters <= 6, e.g. a percentage) sits on the same line as its
-- label; a long one gets its own line under the label.
local function CreateText(parent, def, y)
    local short = def.maxLetters and def.maxLetters <= 6
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetText(def.label)

    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(def.maxLetters or 500)
    if short then
        label:SetPoint("TOPLEFT", PADDING + 30, y - 6)   -- lines up with checkbox labels
        eb:SetSize(44, 20)
        eb:SetPoint("LEFT", label, "RIGHT", 12, 0)
        eb:SetJustifyH("CENTER")
    else
        label:SetPoint("TOPLEFT", PADDING + 30, y - 4)
        eb:SetSize(CONTENT_W - PADDING * 2 - 40, 20)
        eb:SetPoint("TOPLEFT", PADDING + 34, y - 20)
    end

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
    return eb, short and 26 or 46
end

-- Read-only text that a feature fills in (def.getText), e.g. a live list.
local function CreateInfo(parent, def, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", PADDING + 6, y - 4)
    fs:SetWidth(CONTENT_W - PADDING * 2 - 10)
    fs:SetHeight(48)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetTextColor(0.75, 0.75, 0.75)
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

-- Section heading: gold title with a faint line running to the right edge.
local function CreateHeading(parent, text, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", PADDING - 4, y)
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.22)
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -PADDING, 0)
    return 22
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

-- LAYOUT filled in with the registered option definitions, plus an "Other" tab for any
-- option LAYOUT doesn't mention.
local function BuildTabs()
    local byKey, placed = {}, {}
    for _, def in ipairs(ns.options) do byKey[def.key] = def end

    local tabs = {}
    for _, t in ipairs(LAYOUT) do
        local tab = { name = t.name, icon = t.icon, sections = {} }
        for _, s in ipairs(t.sections) do
            local defs = {}
            for _, key in ipairs(s[2]) do
                if byKey[key] and not placed[key] then
                    table.insert(defs, byKey[key])
                    placed[key] = true
                end
            end
            if #defs > 0 then table.insert(tab.sections, { title = s[1], defs = defs }) end
        end
        if #tab.sections > 0 then table.insert(tabs, tab) end
    end

    local rest = {}
    for _, def in ipairs(ns.options) do
        if not placed[def.key] then table.insert(rest, def) end
    end
    if #rest > 0 then
        table.insert(tabs, { name = "Other", icon = OTHER_ICON, sections = { { title = "Other", defs = rest } } })
    end
    return tabs
end

local function CreateTabButton(parent, tab, index, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(SIDEBAR_W - 12, 28)
    b:SetPoint("TOPLEFT", 6, -8 - (index - 1) * 30)

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(1, 1, 1, 0)

    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetPoint("TOPLEFT"); b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetWidth(3)
    b.bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 10, 0)
    icon:SetTexture(tab.icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon = icon

    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    b.text:SetText(tab.name)

    function b:SetSelected(on)
        self.selected = on
        self.bar:SetShown(on)
        self.bg:SetColorTexture(1, 1, 1, on and 0.09 or 0)
        self.text:SetTextColor(on and 1 or 0.72, on and 1 or 0.72, on and 1 or 0.72)
        self.icon:SetDesaturated(not on)
        self.icon:SetAlpha(on and 1 or 0.7)
    end
    b:SetScript("OnEnter", function(self)
        if not self.selected then self.bg:SetColorTexture(1, 1, 1, 0.05); self.text:SetTextColor(1, 1, 1) end
    end)
    b:SetScript("OnLeave", function(self) self:SetSelected(self.selected) end)
    b:SetScript("OnClick", onClick)
    b:SetSelected(false)
    return b
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

function ns:CreateOptionsUI()
    local f = CreateFrame("Frame", "P13TweaksOptionsFrame", UIParent)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()
    tinsert(UISpecialFrames, f:GetName()) -- Escape closes it
    Fill(f, BG)
    Border(f, EDGE)

    -- title bar
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -13)
    title:SetText(ns.name)
    title:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    sub:SetText("options" .. (version and ("  ·  v" .. version) or ""))

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local titleLine = f:CreateTexture(nil, "BORDER")
    titleLine:SetColorTexture(EDGE[1], EDGE[2], EDGE[3], 1)
    titleLine:SetHeight(1)
    titleLine:SetPoint("TOPLEFT", 1, -TITLE_H)
    titleLine:SetPoint("TOPRIGHT", -1, -TITLE_H)

    -- sidebar
    local sidebar = CreateFrame("Frame", nil, f)
    sidebar:SetPoint("TOPLEFT", 1, -TITLE_H - 1)
    sidebar:SetPoint("BOTTOMLEFT", 1, FOOTER_H)
    sidebar:SetWidth(SIDEBAR_W)
    Fill(sidebar, SIDEBAR_BG)
    local sideLine = sidebar:CreateTexture(nil, "BORDER")
    sideLine:SetColorTexture(EDGE[1], EDGE[2], EDGE[3], 1)
    sideLine:SetWidth(1)
    sideLine:SetPoint("TOPRIGHT"); sideLine:SetPoint("BOTTOMRIGHT")

    -- footer hint
    local footLine = f:CreateTexture(nil, "BORDER")
    footLine:SetColorTexture(EDGE[1], EDGE[2], EDGE[3], 1)
    footLine:SetHeight(1)
    footLine:SetPoint("BOTTOMLEFT", 1, FOOTER_H)
    footLine:SetPoint("BOTTOMRIGHT", -1, FOOTER_H)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 12, 8)
    hint:SetText("Hover an option for details.   /p13 help lists the chat commands.")

    -- one page per tab
    local controls, pages, buttons = {}, {}, {}
    local tallest = 0
    local function Select(i)
        for j, page in ipairs(pages) do
            page:SetShown(j == i)
            buttons[j]:SetSelected(j == i)
        end
        P13TweaksDB.optionsTab = i
    end

    local tabs = BuildTabs()
    for i, tab in ipairs(tabs) do
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", SIDEBAR_W + 1, -TITLE_H - 1)
        page:SetWidth(CONTENT_W)
        page:SetPoint("BOTTOM", f, "BOTTOM", 0, FOOTER_H)
        page:Hide()

        local y = -14
        for s, section in ipairs(tab.sections) do
            if s > 1 then y = y - 10 end
            y = y - CreateHeading(page, section.title, y)
            for _, def in ipairs(section.defs) do
                local build = builders[def.type]
                if build then
                    local control, height = build(page, def, y)
                    table.insert(controls, control)
                    y = y - height
                end
            end
        end
        tallest = math.max(tallest, -y + 12)

        pages[i] = page
        buttons[i] = CreateTabButton(sidebar, tab, i, function() Select(i) end)
    end

    local sideNeeded = 8 + #tabs * 30 + 8
    f:SetSize(SIDEBAR_W + CONTENT_W + 2, TITLE_H + math.max(tallest, sideNeeded) + FOOTER_H + 2)

    local saved = tonumber(P13TweaksDB.optionsTab)
    Select((saved and pages[saved]) and saved or 1)

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

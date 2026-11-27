-- P13Tweaks: Progression tab - when each of your characters reached each level.
-- Every level-up is saved with its time (epoch seconds, from time()) in P13TweaksDB.levelLogData, which is
-- shared by all characters on this account, so the tab lists every character you have logged in with.
-- The first time a character is seen, its current level is saved too, marked "first seen": the addon
-- wasn't running when that level was really reached, so its time is only when we first noticed it.
local ADDON_NAME, ns = ...

-- (saved under levelLogData: "levelLog" is the on/off option's key, a boolean)
local function Log()
    if type(P13TweaksDB.levelLogData) ~= "table" then P13TweaksDB.levelLogData = {} end
    return P13TweaksDB.levelLogData
end

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = (realm and realm ~= "") and realm or GetRealmName() or "?"
    return (name or "?") .. "-" .. realm
end

-- The saved entry for the character you're playing (made if missing).
local function Me()
    local log, key = Log(), CharKey()
    local c = log[key]
    if not c then
        c = { levels = {} }
        log[key] = c
    end
    local _, classFile = UnitClass("player")
    c.class = classFile or c.class
    return c
end

local function Record(level, firstSeen)
    if not ns:Get("levelLog") or not level or level < 1 then return end
    local c = Me()
    if c.levels[level] then return end   -- keep the first time a level was reached
    c.levels[level] = { t = time(), seen = firstSeen or nil }
end

---------------------------------------------------------------------------
-- Tab page
---------------------------------------------------------------------------

local page, content, contentW
local pool, used = {}, 0
local ROW_H = 16
local COL_LEVEL, COL_EPOCH, COL_LOCAL = 0, 70, 180

local function Text(x, y, text, font, r, g, b)
    used = used + 1
    local fs = pool[used]
    if not fs then
        fs = content:CreateFontString(nil, "OVERLAY")
        pool[used] = fs
    end
    fs:SetFontObject(font or "GameFontHighlightSmall")
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    fs:SetTextColor(r or 1, g or 1, b or 1)
    fs:Show()
    return fs
end

local function Refresh()
    if not content then return end
    used = 0
    local log, mine = Log(), CharKey()
    local keys = {}
    for k in pairs(log) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if a == mine then return true elseif b == mine then return false end
        return a < b
    end)

    local y = 0
    if #keys == 0 then
        Text(0, y, ns:Get("levelLog") and "No levels recorded yet - they're saved as you level up."
            or "Recording is off (tick the box above).", nil, 0.75, 0.75, 0.75)
        y = y - ROW_H
    end
    for i, key in ipairs(keys) do
        local c = log[key]
        if i > 1 then y = y - 10 end
        local color = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
        local top = 0
        for lvl in pairs(c.levels) do if lvl > top then top = lvl end end
        Text(0, y, key .. "  |cff999999(level " .. top .. ")|r", "GameFontNormal",
            color and color.r or 1, color and color.g or 0.82, color and color.b or 0)
        y = y - 20
        Text(COL_LEVEL, y, "Level", nil, 1, 0.82, 0)
        Text(COL_EPOCH, y, "Epoch", nil, 1, 0.82, 0)
        Text(COL_LOCAL, y, "Local time", nil, 1, 0.82, 0)
        y = y - ROW_H
        local levels = {}
        for lvl in pairs(c.levels) do levels[#levels + 1] = lvl end
        table.sort(levels)
        for _, lvl in ipairs(levels) do
            local e = c.levels[lvl]
            local g = e.seen and 0.6 or 1
            Text(COL_LEVEL, y, tostring(lvl), nil, g, g, g)
            Text(COL_EPOCH, y, tostring(e.t), nil, g, g, g)
            Text(COL_LOCAL, y, date("%Y-%m-%d %H:%M:%S", e.t) .. (e.seen and "  (first seen)" or ""), nil, g, g, g)
            y = y - ROW_H
        end
    end
    for j = used + 1, #pool do pool[j]:Hide() end
    content:SetHeight(-y + 8)
end
ns.RefreshLevelLog = Refresh

ns.customPages.levelLog = function(parent, top, width)
    page = parent
    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 16, top)
    note:SetWidth(width - 40)
    note:SetJustifyH("LEFT")
    note:SetText("Grey rows were already reached before recording started (time = when first seen).")
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, top - 20)
    scroll:SetPoint("BOTTOMRIGHT", -30, 8)
    content = CreateFrame("Frame", nil, scroll)
    contentW = width - 50
    content:SetSize(contentW, 10)
    scroll:SetScrollChild(content)
    parent:HookScript("OnShow", function() C_Timer.After(0, Refresh) end)
    if parent:IsVisible() then C_Timer.After(0, Refresh) end
end

---------------------------------------------------------------------------
-- Option, command, events
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "levelLog", type = "toggle", default = true,
    label = "Record when each level is reached",
    tooltip = "Saves the date and time of every level-up for each of your characters, listed below. "
        .. "Each time is shown as epoch seconds and as your computer's local time.",
    onChange = function(on)
        if on then Record(UnitLevel("player"), true) end
        if page and page:IsVisible() then Refresh() end
    end,
})

ns:RegisterCommand("levels", "open the Progression tab (when each level was reached)", function()
    local f = ns.optionsFrame
    if f then
        f:Show()
        if ns.SelectOptionsTab then ns.SelectOptionsTab("Progression") end
    end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:SetScript("OnEvent", function(_, event, newLevel)
    if event == "PLAYER_LOGIN" then
        Record(UnitLevel("player"), true)
    else
        Record(tonumber(newLevel) or UnitLevel("player"))
    end
    if page and page:IsVisible() then Refresh() end
end)

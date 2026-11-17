-- P13Tweaks feature: quest markers on the world map for what your teammates have done.
-- A "!" marker sits at the quest giver of every quest that
--   * a teammate has already FINISHED and you haven't done (blue), or
--   * a teammate currently has in their log and you don't (green, option),
-- so you know where to walk to pick it up. Quests you couldn't take yet (level, earlier quests...) are greyed
-- with the reason in the tooltip. Hover for the quests and who did them; click to put a waypoint on the giver.
-- Needs QuestieDB (for where quest givers stand) and teammates who also run P13Tweaks. The data comes from
-- QuestShare.lua (ns.QuestHints) and QuestWhere.lua (ns.QuestGiverPoints).
local ADDON_NAME, ns = ...

local ICON = "Interface\\GossipFrame\\AvailableQuestIcon"          -- "!" : a quest to pick up
local ICON_MINE = "Interface\\GossipFrame\\ActiveQuestIcon"        -- "?" : a quest I have, that a teammate already finished (marked where it's done)
local SIZE = 22
local MAX_HINTS = 100

local layer, button
local pool, used = {}, 0
local hints, hintsAt = {}, 0
local lastSig
local convCache = {}   -- "id:mapID" -> points on that map

local function On() return ns:Get("mapQuestHints") end

local function Hints()
    if GetTime() - hintsAt > 3 then
        hintsAt = GetTime()
        hints = ns.QuestHints and ns.QuestHints(ns:Get("mapQuestHintsHas")) or {}
        if #hints > MAX_HINTS then
            for i = #hints, MAX_HINTS + 1, -1 do hints[i] = nil end
        end
    end
    return hints
end

-- Where a quest's givers show on map mapID: { u, v (0..1 on that map), p = the giver point } for the ones that fall on it.
local function PointsOn(hint, mapID)
    local key = hint.id .. ":" .. mapID .. (hint.mine and "m" or "")
    local cached = convCache[key]
    if cached then return cached end
    local out = {}
    -- a quest I have: mark where its work is done (what to kill / collect); one I could pick up: where it's given
    local fn = hint.mine and ns.QuestObjectivePoints or ns.QuestGiverPoints
    local pts = fn and fn(hint.id) or {}
    for _, p in ipairs(pts) do
        local u, v
        if p.uiMap == mapID then
            u, v = p.x / 100, p.y / 100
        elseif C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D then
            -- the giver is on another map (a zone, while we show the continent): go through world coordinates
            local cont, wpos = C_Map.GetWorldPosFromMapPos(p.uiMap, CreateVector2D(p.x / 100, p.y / 100))
            if cont and wpos then
                local _, mpos = C_Map.GetMapPosFromWorldPos(cont, wpos, mapID)
                if mpos then u, v = mpos:GetXY() end
            end
        end
        if u and v and u >= 0 and u <= 1 and v >= 0 and v <= 1 then out[#out + 1] = { u = u, v = v, p = p } end
    end
    if hint.mine and #out > 1 then
        -- the work area is many spawn points: one marker at the middle of the busiest cluster (within ~6 % of the map)
        local R2 = 0.0036
        local bestN, bestI = 0, 1
        for i, a in ipairs(out) do
            local n = 0
            for _, b in ipairs(out) do
                if (a.u - b.u) ^ 2 + (a.v - b.v) ^ 2 <= R2 then n = n + 1 end
            end
            if n > bestN then bestN, bestI = n, i end
        end
        local a, su, sv, k = out[bestI], 0, 0, 0
        for _, b in ipairs(out) do
            if (a.u - b.u) ^ 2 + (a.v - b.v) ^ 2 <= R2 then su, sv, k = su + b.u, sv + b.v, k + 1 end
        end
        out = { { u = su / k, v = sv / k, p = a.p } }
    end
    convCache[key] = out
    return out
end

---------------------------------------------------------------------------
-- Markers
---------------------------------------------------------------------------

local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local lastRaise = 0
-- Keep the marker layer above the map's own picture layers and pins (the painted map hides lower ones).
local function RaiseLayer(child)
    if GetTime() - lastRaise < 1 then return end
    lastRaise = GetTime()
    local kids = { child:GetChildren() }
    local topName = layer:GetFrameStrata()
    local top = STRATA[topName] or 1
    for _, k in ipairs(kids) do
        if k ~= layer then
            local name = k:GetFrameStrata()
            if (STRATA[name] or 1) > top then top, topName = STRATA[name], name end
        end
    end
    if layer:GetFrameStrata() ~= topName then layer:SetFrameStrata(topName) end
    local maxLevel = child:GetFrameLevel()
    for _, k in ipairs(kids) do
        if k ~= layer and k:GetFrameStrata() == topName then maxLevel = math.max(maxLevel, k:GetFrameLevel()) end
    end
    local want = math.min(9999, maxLevel + 1)
    if layer:GetFrameLevel() ~= want then layer:SetFrameLevel(want) end
end

local function ZoneName(uiMap)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(uiMap)
    return info and info.name or ("map " .. uiMap)
end

local function Names(list)
    return table.concat(list, ", ")
end

local function ShowTooltip(self)
    local g = self.group
    if not g then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(g[1].point.name or "Quest giver", 1, 1, 1)
    for i, e in ipairs(g) do
        if i > 6 then GameTooltip:AddLine(("...and %d more"):format(#g - 6), 0.7, 0.7, 0.7); break end
        local h = e.hint
        local lvl = e.level and ("  (level " .. e.level .. ")") or ""
        GameTooltip:AddLine(h.title .. lvl, 1, 0.82, 0)
        if h.mine then
            GameTooltip:AddLine("   " .. Names(h.done) .. " already finished this - you have it (the area where it's done)", 1, 0.75, 0.25, true)
        elseif #h.done > 0 then
            GameTooltip:AddLine("   " .. Names(h.done) .. " finished this", 0.4, 0.75, 1)
        end
        if #h.has > 0 then GameTooltip:AddLine("   " .. Names(h.has) .. " has this quest", 0.5, 1, 0.5) end
        if #h.reasons > 0 then GameTooltip:AddLine("   can't take it yet: " .. h.reasons[1], 1, 0.4, 0.3, true) end
    end
    GameTooltip:AddLine("Click to set a waypoint here", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function SetWaypoint(self)
    local g = self.group
    local p = g and g[1] and g[1].point
    if not p then return end
    local placed = false
    if C_Map.SetUserWaypoint and UiMapPoint and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(p.uiMap)) then
        placed = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(p.uiMap, p.x / 100, p.y / 100))
        if placed and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
    ns:Print((placed and "Waypoint set: " or "Quest giver: ") .. ("%s - %s %.1f, %.1f"):format(p.name or "quest giver", ZoneName(p.uiMap), p.x, p.y))
end

local function Icon()
    used = used + 1
    local b = pool[used]
    if not b then
        b = CreateFrame("Button", nil, layer)
        b:SetSize(SIZE, SIZE)
        b.tex = b:CreateTexture(nil, "OVERLAY")
        b.tex:SetAllPoints()
        b.tex:SetTexture(ICON)
        b:SetScript("OnEnter", ShowTooltip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", SetWaypoint)
        pool[used] = b
    end
    b:Show()
    return b
end

local function Redraw(force)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    local child = sc and sc.Child
    if not (layer and child) then return end
    local mapID = WorldMapFrame:GetMapID()
    local scale, W, H = sc:GetCanvasScale(), child:GetWidth(), child:GetHeight()
    if not (mapID and scale and scale > 0 and scale < math.huge and W and W > 0) then return end
    local sig = ("%d:%.5f:%.0f:%d:%s:%s"):format(mapID, scale, W, math.floor(GetTime() / 3),
        tostring(On()), tostring(ns:Get("mapQuestHintsHas")))
    if sig == lastSig and not force then return end
    lastSig = sig

    for i = 1, used do pool[i]:Hide() end
    used = 0
    if not On() then return end

    RaiseLayer(child)
    layer:SetScale(1 / scale)
    layer:SetSize(W * scale, H * scale)
    local sx, sy = W * scale, H * scale

    -- Quests with the same giver share one marker.
    local groups, order = {}, {}
    for _, h in ipairs(Hints()) do
        local _, level = ns.QuestGiverPoints(h.id)
        for _, pt in ipairs(PointsOn(h, mapID)) do
            local key = math.floor(pt.u * 150) .. "_" .. math.floor(pt.v * 150)
            local g = groups[key]
            if not g then g = { u = pt.u, v = pt.v }; groups[key] = g; order[#order + 1] = g end
            g[#g + 1] = { hint = h, point = pt.p, level = level }
        end
    end
    for _, g in ipairs(order) do
        local b = Icon()
        b.group = g
        b:ClearAllPoints()
        b:SetPoint("CENTER", layer, "TOPLEFT", g.u * sx, -g.v * sy)
        -- colour: blue = a teammate finished one of these, green = only in teammates' logs; grey = none of them can be taken yet
        local anyTake, anyDone, anyMine = false, false, false
        for _, e in ipairs(g) do
            if #e.hint.reasons == 0 then anyTake = true end
            if #e.hint.done > 0 then anyDone = true end
            if e.hint.mine then anyMine = true end
        end
        b.tex:SetTexture(anyMine and ICON_MINE or ICON)
        b.tex:SetDesaturated(true)
        if anyMine then
            b.tex:SetVertexColor(1, 0.75, 0.25, 1)   -- gold "?": one of my quests that a teammate has finished
        elseif not anyTake then
            b.tex:SetVertexColor(0.6, 0.6, 0.6, 0.7)
        elseif anyDone then
            b.tex:SetVertexColor(0.45, 0.75, 1, 1)
        else
            b.tex:SetVertexColor(0.5, 1, 0.5, 1)
        end
    end
end

---------------------------------------------------------------------------
-- Options and setup
---------------------------------------------------------------------------

ns:RegisterOption({
    key = "mapQuestHints",
    type = "toggle",
    label = "Mark quests my teammates have done on the map",
    tooltip = "Puts a marker on the world map at the quest giver of each quest a teammate has already finished and you haven't (blue). Hover it to see the quest and who did it; click to set a waypoint. Greyed markers are quests you can't take yet (hover for why).\n\nNeeds QuestieDB and teammates with P13Tweaks. A Hints button on the map's button row turns it on and off.",
    default = true,
    onChange = function(on)
        if button then button:SetText(on and "Hints: on" or "Hints: off") end
        lastSig = nil
    end,
})

ns:RegisterOption({
    key = "mapQuestHintsHas",
    type = "toggle",
    label = "...and the quests they currently have",
    tooltip = "Also mark (in green) quests a teammate has in their log that you haven't started, so you can pick up the same quests.",
    default = true,
    onChange = function() hintsAt = 0; lastSig = nil end,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not (sc and sc.Child and sc.GetCanvasScale) then return end

    layer = CreateFrame("Frame", nil, sc.Child)
    layer:SetPoint("TOPLEFT", sc.Child, "TOPLEFT")
    layer:SetFrameLevel(sc.Child:GetFrameLevel() + 24)

    button = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    button:SetSize(86, 22)
    button:SetText(On() and "Hints: on" or "Hints: off")
    button:SetFrameLevel(sc:GetFrameLevel() + 100)
    button:SetScript("OnClick", function()
        ns:Set("mapQuestHints", not On())   -- runs the option's onChange (button text)
        if ns.RefreshOptions then pcall(ns.RefreshOptions, ns) end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("Teammate quest markers")
        GameTooltip:AddLine("Marks on the map where to pick up quests your teammates have done (blue) or currently have (green).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ns:AddMapButton(button, 36)

    local poll = CreateFrame("Frame", nil, WorldMapFrame)
    poll:SetScript("OnUpdate", function() Redraw(false) end)
    poll:SetScript("OnShow", function() hintsAt = 0; Redraw(true) end)
end)

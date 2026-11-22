-- P13Tweaks feature: tilesheet world map (prototype).
-- Draws a whole continent as ONE continuous sheet of the game's terrain tiles (the same tiles
-- MapTerrain uses) in a window of our own, with our own zoom and pan: no map levels, no
-- hand-overs, nothing from the game's map to fight with. Mouse wheel zooms smoothly around the
-- cursor, left-drag pans, middle-click centres on you. Memory-hungry on purpose for now: it just
-- draws every tile in view at any zoom; optimising comes after it works.
--
-- Everything is in "tile units": tile (col, row) covers x from col to col+1 and y from row to
-- row+1, y growing downward, exactly as the terrain tiles are laid out (see MapTerrain.lua).
-- A world position (worldX, worldY) as C_Map.GetWorldPosFromMapPos gives them is at
-- x = 32 - worldY / 533.33, y = 32 - worldX / 533.33.
local ADDON_NAME, ns = ...

local ARROW = "Interface\\AddOns\\P13Tweaks\\Media\\Arrow.tga"
local TILE_YARDS = 533.33333
local MAX_ZOOM   = 1600    -- screen pixels per tile (a tile's own picture is 256 px wide)
local WHEEL_STEP = 1.35    -- zoom factor per wheel notch
local SMOOTH     = 14      -- how fast the zoom eases toward its target (per second)
local SEA_R, SEA_G, SEA_B = 0.04, 0.16, 0.25
local WORLDS = { { 0, "Eastern Kingdoms" }, { 1, "Kalimdor" }, { 2991, "Zephras Isle" } }

local frame, view, coordText, playerMark
local world, ids
local minCol, maxCol, minRow, maxRow = 0, 63, 0, 63
local cx, cy = 32, 32               -- the tile-unit point at the middle of the view
local zoom, zoomTarget, minZoom = 10, 10, 4   -- screen pixels per tile
local anchorTx, anchorTy, anchorSx, anchorSy  -- map point to keep under the cursor while zooming
local dragging, dragPx, dragPy, dragCx, dragCy
local tilesInUse, spare = {}, {}
local lastCx, lastCy, lastZoom, lastW, lastH
local mapIDCache, mapIDTime = nil, 0

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

---------------------------------------------------------------------------
-- Cursor and player
---------------------------------------------------------------------------

-- Cursor position in screen pixels from the middle of the view (x right, y down).
local function CursorOffset()
    local px, py = GetCursorPosition()
    local es = view:GetEffectiveScale()
    local l, t = view:GetLeft(), view:GetTop()
    if not (l and t) then return 0, 0 end
    return px / es - l - view:GetWidth() / 2, (t - py / es) - view:GetHeight() / 2
end

-- Where the player is on the sheet, if they're in this world.
local function PlayerTile()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
    local now = GetTime()
    if now - mapIDTime > 0.5 then mapIDCache, mapIDTime = C_Map.GetBestMapForUnit("player"), now end
    if not mapIDCache then return end
    local pos = C_Map.GetPlayerMapPosition(mapIDCache, "player")
    if not pos then return end
    local px, py = pos:GetXY()
    if not px or (px == 0 and py == 0) then return end
    local inst, wp = C_Map.GetWorldPosFromMapPos(mapIDCache, CreateVector2D(px, py))
    if inst ~= world or not wp then return end
    local wx, wy = wp:GetXY()
    return 32 - wy / TILE_YARDS, 32 - wx / TILE_YARDS
end

---------------------------------------------------------------------------
-- Tiles
---------------------------------------------------------------------------

local function ReleaseAll()
    for key, t in pairs(tilesInUse) do
        t:Hide()
        t:SetTexture(nil)
        spare[#spare + 1] = t
        tilesInUse[key] = nil
    end
end

local function Draw()
    local w, h = view:GetWidth(), view:GetHeight()
    if not (ids and w and w > 0 and h and h > 0) then return end
    if cx == lastCx and cy == lastCy and zoom == lastZoom and w == lastW and h == lastH then return end
    lastCx, lastCy, lastZoom, lastW, lastH = cx, cy, zoom, w, h

    local halfC, halfR = w / zoom / 2, h / zoom / 2
    local c0, c1 = math.max(minCol, math.floor(cx - halfC)), math.min(maxCol, math.floor(cx + halfC))
    local r0, r1 = math.max(minRow, math.floor(cy - halfR)), math.min(maxRow, math.floor(cy + halfR))
    local size = zoom + 1   -- a pixel of overlap hides hairline seams
    local wanted = {}
    for col = c0, c1 do
        for row = r0, r1 do
            local key = col * 64 + row
            local id = ids[key]
            if id then
                wanted[key] = true
                local t = tilesInUse[key]
                if not t then
                    t = table.remove(spare) or view:CreateTexture(nil, "ARTWORK")
                    t:SetTexture(id)
                    t:Show()
                    tilesInUse[key] = t
                end
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", view, "TOPLEFT", (col - cx) * zoom + w / 2, -((row - cy) * zoom + h / 2))
                t:SetSize(size, size)
            end
        end
    end
    for key, t in pairs(tilesInUse) do
        if not wanted[key] then
            t:Hide()
            t:SetTexture(nil)
            spare[#spare + 1] = t
            tilesInUse[key] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Worlds
---------------------------------------------------------------------------

local function SetWorld(w)
    world = w
    ids = ns.TerrainTiles and ns.TerrainTiles[w]
    ReleaseAll()
    lastCx = nil
    if not ids then return end
    minCol, maxCol, minRow, maxRow = 63, 0, 63, 0
    for key in pairs(ids) do
        local col, row = math.floor(key / 64), key % 64
        if col < minCol then minCol = col end
        if col > maxCol then maxCol = col end
        if row < minRow then minRow = row end
        if row > maxRow then maxRow = row end
    end
    cx, cy = (minCol + maxCol + 1) / 2, (minRow + maxRow + 1) / 2
    local vw, vh = view:GetWidth(), view:GetHeight()
    local fit = math.min(vw / (maxCol - minCol + 1), vh / (maxRow - minRow + 1))
    minZoom = math.max(1, fit * 0.5)
    zoom = Clamp(fit * 0.95, minZoom, MAX_ZOOM)
    zoomTarget = zoom
    anchorTx = nil
end

local function PlayerWorld()
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local id = C_Map.GetBestMapForUnit("player")
        if id then
            local inst = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(0.5, 0.5))
            if inst and ns.TerrainTiles and ns.TerrainTiles[inst] then return inst end
        end
    end
    return 1
end

local function CentreOnPlayer(closeUp)
    local tx, ty = PlayerTile()
    if not tx then return end
    cx, cy = tx, ty
    anchorTx = nil
    if closeUp then zoomTarget = Clamp(math.max(zoomTarget, 200), minZoom, MAX_ZOOM) end
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function OnUpdate(_, dt)
    if dragging then
        local px, py = GetCursorPosition()
        local es = view:GetEffectiveScale()
        cx = dragCx - (px - dragPx) / es / zoom
        cy = dragCy + (py - dragPy) / es / zoom
        anchorTx = nil
    end

    if zoom ~= zoomTarget then
        zoom = zoom + (zoomTarget - zoom) * (1 - math.exp(-SMOOTH * dt))
        if math.abs(zoomTarget - zoom) < zoomTarget * 0.0005 then zoom = zoomTarget end
        if anchorTx then   -- keep the map point you zoomed on exactly under the cursor
            cx, cy = anchorTx - anchorSx / zoom, anchorTy - anchorSy / zoom
        end
        if zoom == zoomTarget then anchorTx = nil end
    end

    cx, cy = Clamp(cx, minCol - 4, maxCol + 5), Clamp(cy, minRow - 4, maxRow + 5)
    Draw()

    -- the player's arrow
    local w, h = view:GetWidth(), view:GetHeight()
    local tx, ty = PlayerTile()
    if tx then
        playerMark:ClearAllPoints()
        playerMark:SetPoint("CENTER", view, "TOPLEFT", (tx - cx) * zoom + w / 2, -((ty - cy) * zoom + h / 2))
        playerMark:SetRotation(GetPlayerFacing() or 0)
        playerMark:Show()
    else
        playerMark:Hide()
    end

    -- which tile the cursor is over (handy for spotting bad tiles)
    if view:IsMouseOver() then
        local sx, sy = CursorOffset()
        local col, row = math.floor(cx + sx / zoom), math.floor(cy + sy / zoom)
        coordText:SetText(("tile %d,%d  id %s  zoom %.0f px/tile"):format(col, row,
            tostring(ids and ids[col * 64 + row]), zoom))
    end
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "P13SheetFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(math.floor(UIParent:GetWidth() * 0.8), math.floor(UIParent:GetHeight() * 0.8))
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    if frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        frame:SetBackdropColor(0, 0, 0, 0.95)
        frame:SetBackdropBorderColor(0.6, 0.5, 0.2, 1)
    end
    table.insert(UISpecialFrames, "P13SheetFrame")   -- Escape closes it

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -9)
    title:SetText("Tile map")
    local drag = CreateFrame("Frame", nil, frame)
    drag:SetPoint("TOPLEFT")
    drag:SetPoint("TOPRIGHT", -30, 0)
    drag:SetHeight(26)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() frame:StartMoving() end)
    drag:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    -- world buttons, on a bar of their own raised above the title/drag area so nothing covers them
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", 90, -4)
    bar:SetSize(400, 22)
    bar:SetFrameLevel(frame:GetFrameLevel() + 20)
    local prev
    for _, wd in ipairs(WORLDS) do
        local b = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
        b:SetSize(120, 20)
        b:SetText(wd[2])
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("LEFT", bar, "LEFT", 0, 0) end
        b:RegisterForClicks("LeftButtonUp")
        b:SetScript("OnClick", function()
            local ok, err = pcall(SetWorld, wd[1])
            local n = 0
            for _ in pairs(ns.TerrainTiles and ns.TerrainTiles[wd[1]] or {}) do n = n + 1 end
            ns:Print(("tile map: %s - %d tiles%s"):format(wd[2], n, ok and "" or (" - ERROR: " .. tostring(err))))
        end)
        prev = b
    end

    view = CreateFrame("Frame", nil, frame)
    view:SetPoint("TOPLEFT", 6, -30)
    view:SetPoint("BOTTOMRIGHT", -6, 6)
    if view.SetClipsChildren then view:SetClipsChildren(true) end
    view:EnableMouse(true)
    view:EnableMouseWheel(true)

    local sea = view:CreateTexture(nil, "BACKGROUND")
    sea:SetAllPoints()
    sea:SetColorTexture(SEA_R, SEA_G, SEA_B, 1)

    playerMark = view:CreateTexture(nil, "OVERLAY")
    playerMark:SetSize(22, 22)
    playerMark:SetTexture(ARROW)
    playerMark:SetVertexColor(1, 0.85, 0.1)
    playerMark:Hide()

    coordText = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coordText:SetPoint("BOTTOMLEFT", 6, 4)

    view:SetScript("OnMouseWheel", function(_, delta)
        local sx, sy = CursorOffset()
        anchorTx, anchorTy, anchorSx, anchorSy = cx + sx / zoom, cy + sy / zoom, sx, sy
        zoomTarget = Clamp(zoomTarget * (delta > 0 and WHEEL_STEP or 1 / WHEEL_STEP), minZoom, MAX_ZOOM)
    end)
    view:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            dragging = true
            dragPx, dragPy = GetCursorPosition()
            dragCx, dragCy = cx, cy
        elseif button == "MiddleButton" then
            CentreOnPlayer(true)
        end
    end)
    view:SetScript("OnMouseUp", function() dragging = false end)
    view:SetScript("OnUpdate", OnUpdate)

    frame:Hide()
end

local function Toggle()
    if not ns:Get("mapSheet") then ns:Print("The tile map is switched off in /p13.") return end
    Build()
    if frame:IsShown() then
        frame:Hide()
        return
    end
    frame:Show()
    if not world then
        SetWorld(PlayerWorld())
        CentreOnPlayer(false)
    end
end

ns:RegisterCommand("sheet", "open the tilesheet world map", Toggle)

ns:RegisterOption({
    key = "mapSheet",
    type = "toggle",
    label = "Tilesheet world map (Tile map button on the map, /p13 sheet)",
    tooltip = "A world map of our own: the whole continent as one continuous sheet of terrain tiles. Mouse wheel zooms smoothly around the cursor, drag to pan, middle-click centres on you. Prototype: uses a lot of memory when zoomed out.",
    default = true,
    onChange = function(v)
        if not v and frame then frame:Hide() end
        if ns.sheetButton then ns.sheetButton:SetShown(v and true or false) end
    end,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc then return end
    local button = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    button:SetSize(100, 22)
    button:SetText("Tile map")
    button:SetScript("OnClick", Toggle)
    ns.sheetButton = button
    ns:AddMapButton(button, 30)
    button:SetShown(ns:Get("mapSheet") and true or false)
end)

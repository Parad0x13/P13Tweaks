-- P13Tweaks feature: when the world map opens, a ring shrinks in onto your position.
local ADDON_NAME, ns = ...

local TEXTURE = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\Ring"
local START_SIZE, END_SIZE = 600, 48   -- ring diameter in map pixels
local ZOOM_TIME, HOLD_TIME, FADE_TIME = 0.6, 0.25, 0.4
local COLOR = { 1.0, 0.82, 0.0 }        -- gold

local ring, elapsed

local function EaseOut(t) return 1 - (1 - t) ^ 3 end

-- Returns the player's 0-1 position on the map currently shown, or nil if not on it.
local function GetPlayerPos()
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return end
    return x, y
end

local function UpdateRing(self, dt)
    elapsed = elapsed + dt
    local x, y = GetPlayerPos()
    if not x or elapsed > ZOOM_TIME + HOLD_TIME + FADE_TIME then
        self:Hide()
        return
    end

    -- Keep the ring the same on-screen size no matter how far the map is zoomed.
    local canvas = WorldMapFrame:GetCanvas()
    local scale = 1 / WorldMapFrame:GetCanvasScale()
    self:SetScale(scale)
    self:ClearAllPoints()
    self:SetPoint("CENTER", canvas, "TOPLEFT", canvas:GetWidth() * x / scale, -canvas:GetHeight() * y / scale)

    local size, alpha
    if elapsed < ZOOM_TIME then
        local t = EaseOut(elapsed / ZOOM_TIME)
        size = START_SIZE + (END_SIZE - START_SIZE) * t
        alpha = 0.3 + 0.7 * t
    elseif elapsed < ZOOM_TIME + HOLD_TIME then
        size = END_SIZE
        alpha = 1
    else
        size = END_SIZE
        alpha = 1 - (elapsed - ZOOM_TIME - HOLD_TIME) / FADE_TIME
    end
    self:SetSize(size, size)
    self:SetAlpha(alpha)
end

local function Play()
    if not ns:Get("mapPlayerCircle") or not WorldMapFrame:IsShown() then return end
    if ns.suppressMapRing then return end   -- e.g. the F key switched maps
    if not GetPlayerPos() then return end
    elapsed = 0
    ring:Show()
end

local function Setup()
    ring = CreateFrame("Frame", nil, WorldMapFrame:GetCanvas())
    ring:SetFrameStrata("HIGH")
    ring:SetFrameLevel(100)
    ring:Hide()
    local tex = ring:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(TEXTURE)
    tex:SetVertexColor(unpack(COLOR))
    tex:SetBlendMode("ADD")
    ring:SetScript("OnUpdate", UpdateRing)

    WorldMapFrame:HookScript("OnShow", Play)
    -- Also replay when you browse back to a map you're on (e.g. zone -> continent -> zone).
    if WorldMapFrame.OnMapChanged then
        hooksecurefunc(WorldMapFrame, "OnMapChanged", Play)
    end
end

ns:RegisterOption({
    key = "mapPlayerCircle",
    type = "toggle",
    label = "Highlight my position when the map opens",
    tooltip = "A ring zooms in onto your location each time you open the world map.",
    default = true,
    onChange = function(on) if not on and ring then ring:Hide() end end,
})

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    if WorldMapFrame and WorldMapFrame.GetCanvas then
        Setup()
    end
end)

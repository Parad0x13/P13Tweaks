-- P13Tweaks feature: middle-click (wheel click) the world map to centre and zoom in on yourself,
-- same as the map's Center button.
local ADDON_NAME, ns = ...

local pressedOnMap = false

local function OnMouseDown(sc, button)
    if button == "MiddleButton" then pressedOnMap = true end
end

local function OnMouseUp(sc, button)
    if button ~= "MiddleButton" then return end
    local wasPressed = pressedOnMap
    pressedOnMap = false
    -- same as the map's Center button: centre on you and zoom in close
    if wasPressed and ns:Get("mapMiddleClick") and ns.CentreMapOnPlayer then ns.CentreMapOnPlayer(true) end
end

ns:RegisterOption({
    key = "mapMiddleClick",
    type = "toggle",
    label = "Middle-click the map to centre on me",
    tooltip = "Click the mouse wheel button on the world map to switch to your zone, centre on your position and zoom in close, the same as the map's Center button. Works in combat too.",
    default = true,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    P13TweaksDB.mapMiddleDrag = nil   -- removed option (middle-button drag)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc then return end
    sc:HookScript("OnMouseDown", OnMouseDown)
    sc:HookScript("OnMouseUp", OnMouseUp)
    WorldMapFrame:HookScript("OnHide", function() pressedOnMap = false end)
end)

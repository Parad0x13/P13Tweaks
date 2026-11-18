-- P13Tweaks feature: middle-click (wheel click) any slot in your bags to sort the bags,
-- same as the bag's sort button. (Only works where the game has a bag-sort function.)
local ADDON_NAME, ns = ...

local hooked = setmetatable({}, { __mode = "k" })
local pressed

local function Sort()
    if C_Container and C_Container.SortBags then C_Container.SortBags()
    elseif SortBags then SortBags()
    else ns:Print("This version of the game has no bag sorting.") end
end

local lastSort = 0
local function SortOnce()
    if GetTime() - lastSort < 0.3 then return end   -- (the slot hook and the global listener can both see one click)
    lastSort = GetTime()
    Sort()
end

-- Is this frame a bag slot, or inside a bag window?
local function InBag(f)
    for _ = 1, 6 do
        if not f then return false end
        local n = f.GetName and f:GetName()
        if n and (n:find("^ContainerFrame") or n:find("^BackpackFrame")) then return true end
        if f.GetBagID and f.GetID then return true end
        f = f.GetParent and f:GetParent()
    end
    return false
end

-- Bag addons built on the Bagnon / BagBrother library draw their own windows: their bag frames have SortItems()
-- (what their cleanup button runs). Returns that frame if the mouse is over one (not an offline character's bags).
local function AddonBagFrame(f)
    for _ = 1, 8 do
        if not f then return nil end
        local owner = type(f.frame) == "table" and f.frame or nil
        for _, c in ipairs({ f, owner or f }) do
            if type(c.SortItems) == "function" then
                if c.IsCached and c:IsCached() then return nil end
                return c
            end
        end
        f = f.GetParent and f:GetParent()
    end
end

local function MouseFocus()
    if GetMouseFoci then local t = GetMouseFoci(); return t and t[1] end
    if GetMouseFocus then return GetMouseFocus() end
end

local function Hook(b)
    if not b or hooked[b] or not b.HookScript then return end
    hooked[b] = true
    b:HookScript("OnMouseDown", function(self, button)
        pressed = (button == "MiddleButton") and self or nil
    end)
    b:HookScript("OnMouseUp", function(self, button)
        local was = pressed
        pressed = nil
        if button == "MiddleButton" and was == self and ns:Get("bagMiddleSort") then SortOnce() end
    end)
end

-- Fallback that doesn't depend on hooking the slot buttons: the game's global mouse events.
local gm = CreateFrame("Frame")
if pcall(gm.RegisterEvent, gm, "GLOBAL_MOUSE_UP") then
    gm:SetScript("OnEvent", function(_, _, button)
        if button ~= "MiddleButton" or not ns:Get("bagMiddleSort") then return end
        local f = MouseFocus()
        local ab = AddonBagFrame(f)
        if ab then
            if GetTime() - lastSort > 0.3 then lastSort = GetTime(); pcall(ab.SortItems, ab) end
        elseif InBag(f) then
            SortOnce()
        end
    end)
end

ns:RegisterCommand("bagdebug", "show what the mouse is over (for the bag middle-click sort)", function()
    local f = MouseFocus()
    ns:Print(("mouse over: %s | counts as a bag: %s | sort function: %s | global mouse event: %s"):format(
        tostring(f and f.GetName and f:GetName() or f), tostring(InBag(f)),
        tostring((C_Container and C_Container.SortBags and "C_Container.SortBags") or (SortBags and "SortBags") or "none"),
        tostring(gm:IsEventRegistered("GLOBAL_MOUSE_UP"))))
end)

local function HookFrame(f)
    if not f then return end
    if f.EnumerateValidItems then
        for _, b in f:EnumerateValidItems() do Hook(b) end
    end
    local name = f.GetName and f:GetName()
    if name then
        for i = 1, 40 do Hook(_G[name .. "Item" .. i]) end
    end
end

local function HookAll()
    for i = 1, 13 do HookFrame(_G["ContainerFrame" .. i]) end
    HookFrame(_G.ContainerFrameCombinedBags)
end

ns:RegisterOption({
    key = "bagMiddleSort",
    type = "toggle",
    label = "Middle-click a bag slot to sort the bags",
    tooltip = "Click the mouse wheel button on any slot in your bags to sort them, the same as the bag's sort button.",
    default = true,
})

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:SetScript("OnEvent", function() HookAll() end)   -- slots appear as bags open / change size
if hooksecurefunc then
    if _G.ContainerFrame_GenerateFrame then hooksecurefunc("ContainerFrame_GenerateFrame", HookAll) end
    if _G.ContainerFrame_Update then hooksecurefunc("ContainerFrame_Update", HookAll) end
    if _G.OpenBag then hooksecurefunc("OpenBag", function() C_Timer.After(0, HookAll) end) end
    if _G.ToggleBag then hooksecurefunc("ToggleBag", function() C_Timer.After(0, HookAll) end) end
    if _G.OpenAllBags then hooksecurefunc("OpenAllBags", function() C_Timer.After(0, HookAll) end) end
    if _G.ToggleAllBags then hooksecurefunc("ToggleAllBags", function() C_Timer.After(0, HookAll) end) end
end

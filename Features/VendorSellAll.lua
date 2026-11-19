-- P13Tweaks feature: Ctrl + right-click a bag item while a vendor window is open to sell ALL stacks of that item.
-- A normal right-click still sells just the one stack. The vendor only remembers 12 sold things for buyback,
-- so at most 12 stacks are sold per Ctrl + right-click; you can always buy them back from the Buyback tab.
local ADDON_NAME, ns = ...

local MAX_STACKS = 12     -- the vendor's buyback list holds 12
local STEP = 0.08         -- seconds between sales
local MAX_BAG = 5         -- bags 0 (backpack) ... 4, plus 5 if the client has a reagent bag

local C = C_Container
local function SlotInfo(bag, slot)
    if C and C.GetContainerItemInfo then return C.GetContainerItemInfo(bag, slot) end
    if GetContainerItemInfo then
        local _, count, locked, _, _, _, link, _, noValue, id = GetContainerItemInfo(bag, slot)
        if not link then return nil end
        return { stackCount = count, isLocked = locked, hyperlink = link, hasNoValue = noValue, itemID = id }
    end
end
local function UseSlot(bag, slot)
    if C and C.UseContainerItem then C.UseContainerItem(bag, slot) else UseContainerItem(bag, slot) end
end

local function MouseFocus()
    if GetMouseFoci then local t = GetMouseFoci(); return t and t[1] end
    if GetMouseFocus then return GetMouseFocus() end
end

-- Which bag and slot is this button? (default bags, and addon bags that expose GetBagID / GetBag)
local function SlotOf(f)
    for _ = 1, 3 do
        if not f then return nil end
        local slot = f.GetID and f:GetID()
        local bag = (f.GetBagID and f:GetBagID()) or (f.GetBag and f:GetBag())
            or (f.GetParent and f:GetParent() and f:GetParent().GetID and f:GetParent():GetID())
        if type(bag) == "number" and type(slot) == "number" and slot > 0 and bag >= 0 and bag <= MAX_BAG then
            return bag, slot
        end
        f = f.GetParent and f:GetParent()
    end
end

local busy = false

-- Sell the other stacks of the item the mouse was on. `first` is the clicked slot, which the game's own
-- right-click handling is already selling, so it counts as stack number one.
local function SellRest(itemID, firstBag, firstSlot)
    local queue, link = {}, nil
    for bag = 0, MAX_BAG do
        for slot = 1, (C and C.GetContainerNumSlots and C.GetContainerNumSlots(bag) or GetContainerNumSlots(bag) or 0) do
            if not (bag == firstBag and slot == firstSlot) then
                local info = SlotInfo(bag, slot)
                if info and info.itemID == itemID and not info.isLocked and not info.hasNoValue then
                    table.insert(queue, { bag, slot })
                    link = link or info.hyperlink
                end
            end
        end
    end
    local room = MAX_STACKS - 1
    local n = math.min(#queue, room)
    if n == 0 then return end
    busy = true
    for i = 1, n do
        C_Timer.After(i * STEP, function()
            if MerchantFrame and MerchantFrame:IsShown() then UseSlot(queue[i][1], queue[i][2]) end
            if i == n then busy = false end
        end)
    end
    ns:Print(("Sold %d stacks of %s (the Buyback tab keeps the last %d)%s"):format(n + 1,
        link or "that item", MAX_STACKS, #queue > room and " - more remain in your bags" or ""))
end

local gm = CreateFrame("Frame")
if pcall(gm.RegisterEvent, gm, "GLOBAL_MOUSE_DOWN") then
    gm:SetScript("OnEvent", function(_, _, button)
        if button ~= "RightButton" or not IsControlKeyDown() or busy then return end
        if not ns:Get("vendorSellAll") then return end
        if not (MerchantFrame and MerchantFrame:IsShown()) then return end
        local bag, slot = SlotOf(MouseFocus())
        if not bag then return end
        local info = SlotInfo(bag, slot)
        if not (info and info.itemID) or info.hasNoValue then return end
        -- look after the game's own right-click sale has started, so the clicked stack isn't counted twice
        local id = info.itemID
        C_Timer.After(0.15, function() SellRest(id, bag, slot) end)
    end)
end

ns:RegisterOption({
    key = "vendorSellAll",
    type = "toggle",
    label = "Vendor: Ctrl + right-click sells every stack of that item",
    tooltip = "While a vendor window is open, Ctrl + right-click an item in your bags to sell ALL stacks of that same item (up to 12 stacks, the most the vendor's Buyback tab can hold, so you can always buy them back). A plain right-click still sells one stack.",
    default = true,
})

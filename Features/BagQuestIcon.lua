-- P13Tweaks feature: a small "!" in the top-left corner of quest items in your bags,
-- so they stand out at a glance. Works on the game's own bag windows and on Bagnon.
local ADDON_NAME, ns = ...

local ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local QUEST_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local marks = setmetatable({}, { __mode = "k" })   -- item button -> its "!" texture

-- bag and slot of a bag item button (modern buttons have GetBagID; older ones use the parent bag's ID)
local function BagSlot(b)
    local bag
    if b.GetBagID then bag = b:GetBagID()
    elseif b.GetBag then bag = b:GetBag()   -- Bagnon
    else local p = b:GetParent(); bag = p and p.GetID and p:GetID() end
    return bag, b.GetID and b:GetID()
end

local function IsQuestItem(bag, slot)
    if C_Container and C_Container.GetContainerItemQuestInfo then
        local q = C_Container.GetContainerItemQuestInfo(bag, slot)
        if q and (q.isQuestItem or q.questID) then return true end
    elseif _G.GetContainerItemQuestInfo then
        local isQuest, questID = _G.GetContainerItemQuestInfo(bag, slot)
        if isQuest or questID then return true end
    end
    local id = (C_Container and C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot))
        or (_G.GetContainerItemID and _G.GetContainerItemID(bag, slot))
    if not id then return false end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    local classID = getInstant and select(6, getInstant(id))
    return classID == QUEST_CLASS
end

local function Mark(b)
    local t = marks[b]
    if not t then
        t = b:CreateTexture(nil, "OVERLAY", nil, 7)
        t:SetTexture(ICON)
        t:SetSize(14, 14)
        t:SetPoint("TOPLEFT", b, "TOPLEFT", -2, 2)
        marks[b] = t
    end
    return t
end

local function UpdateButton(b)
    if not b or not b.IsShown then return end
    local show = false
    if ns:Get("bagQuestIcon") and b:IsShown() then
        local bag, slot = BagSlot(b)
        if bag and slot and slot > 0 then show = IsQuestItem(bag, slot) end
    end
    if show then Mark(b):Show()
    elseif marks[b] then marks[b]:Hide() end
end

-- Is this frame a bag item button? (has an ID, and either GetBagID or a bag-window parent)
local function IsItemButton(b)
    if not (b and b.GetID and b.IsObjectType and b:IsObjectType("Button")) then return false end
    return b.GetBagID ~= nil or (b.icon or b.Icon or b.IconTexture or (b.GetName and b:GetName() and _G[b:GetName() .. "IconTexture"])) ~= nil
end

local stats = { frames = 0, buttons = 0, quest = 0 }

-- Every bag item button inside a bag window, found by walking its child frames (doesn't rely on
-- button names or the EnumerateValidItems helper, which differ between game versions).
local function Collect(f, out, seen, depth)
    if not f or seen[f] or depth > 4 then return end
    seen[f] = true
    if IsItemButton(f) and depth > 0 then out[#out + 1] = f; return end
    if f.GetChildren then
        for _, c in ipairs({ f:GetChildren() }) do Collect(c, out, seen, depth + 1) end
    end
end

local function UpdateFrame(f, seen)
    if not f then return end
    stats.frames = stats.frames + 1
    local list = {}
    if f.EnumerateValidItems then
        -- (some game versions give (index, button), others give the button first)
        for a, b in f:EnumerateValidItems() do
            local btn = (type(b) == "table" and b) or (type(a) == "table" and a) or nil
            if btn and not seen[btn] then list[#list + 1] = btn; seen[btn] = true end
        end
    end
    Collect(f, list, seen, 0)
    for _, b in ipairs(list) do
        stats.buttons = stats.buttons + 1
        UpdateButton(b)
        if marks[b] and marks[b]:IsShown() then stats.quest = stats.quest + 1 end
    end
end

local function UpdateAll()
    stats.frames, stats.buttons, stats.quest = 0, 0, 0
    local seen = {}
    for i = 1, 13 do UpdateFrame(_G["ContainerFrame" .. i], seen) end
    UpdateFrame(_G.ContainerFrameCombinedBags, seen)
    UpdateFrame(_G.BackpackFrame, seen)
end

-- Bagnon (its code lives in the BagBrother addon) draws its own bag windows. Every one of its item slots
-- redraws through Item:UpdateBorder, so hook that and use Bagnon's own quest check plus the item category.
local bagnonQuest = setmetatable({}, { __mode = "k" })   -- Bagnon button -> is it a quest item
local bagnonHooked = false
local function HookBagnon()
    -- (the addon table is named after whichever addon loads the shared code: "Bagnon" on Forever)
    local BB
    for _, n in ipairs({ "Bagnon", "BagBrother", "Combuctor", "Bagnonium" }) do
        local t = _G[n]
        if type(t) == "table" and type(t.Item) == "table" and t.Item.UpdateBorder then BB = t; break end
    end
    if bagnonHooked or not BB then return end
    bagnonHooked = true
    hooksecurefunc(BB.Item, "UpdateBorder", function(b)
        local q = false
        if b.hasItem and b.info then
            local ok, quest, bang = pcall(b.GetQuestInfo, b)
            q = (ok and (quest or bang)) and true or false
            if not q and b.info.itemID then
                local getInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
                q = (getInstant and select(6, getInstant(b.info.itemID))) == QUEST_CLASS
            end
        end
        bagnonQuest[b] = q
        if q and ns:Get("bagQuestIcon") then Mark(b):Show()
        elseif marks[b] then marks[b]:Hide() end
    end)
end

local function RefreshBagnon()
    for b, q in pairs(bagnonQuest) do
        if q and ns:Get("bagQuestIcon") then Mark(b):Show()
        elseif marks[b] then marks[b]:Hide() end
    end
end

local pending = false
local function UpdateSoon()
    if pending then return end
    pending = true
    C_Timer.After(0, function() pending = false; UpdateAll() end)
end

ns:RegisterOption({
    key = "bagQuestIcon",
    type = "toggle",
    label = "Mark quest items in your bags",
    tooltip = "Puts a small yellow ! in the top-left corner of quest items in your bags so you can spot them quickly. Works in the game's own bags and in Bagnon.",
    default = true,
    onChange = function() UpdateAll(); RefreshBagnon() end,
})

ns:RegisterCommand("bagquest", "check the bag quest-item marks (hover a bag slot first)", function()
    UpdateAll()
    -- saved too (P13TweaksDB.bagQuestDebug), since chat text can't be copied: /reload writes it to disk
    local log = {}
    P13TweaksDB.bagQuestDebug = log
    local function Out(s) ns:Print(s); log[#log + 1] = s end
    local nB, nQ, nM = 0, 0, 0
    for b, q in pairs(bagnonQuest) do
        nB = nB + 1
        if q then nQ = nQ + 1 end
        if marks[b] and marks[b]:IsShown() then nM = nM + 1 end
    end
    Out(("version %s | option on: %s | game bag windows: %d | slots found: %d | quest items marked: %d"):format(
        tostring(ns.version), tostring(ns:Get("bagQuestIcon")), stats.frames, stats.buttons, stats.quest))
    Out(("Bagnon loaded: %s | hooked: %s | Bagnon slots seen: %d | quest: %d | marked: %d"):format(
        tostring(_G.Bagnon ~= nil or _G.BagBrother ~= nil), tostring(bagnonHooked), nB, nQ, nM))
    local f = (GetMouseFoci and (GetMouseFoci() or {})[1]) or (GetMouseFocus and GetMouseFocus())
    if not f then Out("mouse over: nothing"); ns:Print("Saved. Type /reload so the results are written to disk."); return end
    local bag, slot = BagSlot(f)
    local id = bag and slot and ((C_Container and C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot))
        or (_G.GetContainerItemID and _G.GetContainerItemID(bag, slot)))
    local q = bag and slot and C_Container and C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    Out(("mouse over: %s | item button: %s | bag %s slot %s | item %s | class %s | game quest flag %s | Bagnon quest %s | marked %s"):format(
        tostring(f.GetName and f:GetName() or f), tostring(IsItemButton(f)), tostring(bag), tostring(slot), tostring(id),
        tostring(id and getInstant and select(6, getInstant(id))), tostring(q and (q.isQuestItem or q.questID)),
        tostring(bagnonQuest[f]), tostring(marks[f] ~= nil and marks[f]:IsShown())))
    ns:Print("Saved. Type /reload so the results are written to disk.")
end)

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "BAG_UPDATE_DELAYED", "QUEST_ACCEPTED", "QUEST_LOG_UPDATE", "GET_ITEM_INFO_RECEIVED" }) do
    pcall(events.RegisterEvent, events, e)
end
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        HookBagnon()
        return
    end
    if event == "PLAYER_LOGIN" then HookBagnon() end
    UpdateSoon()
end)
HookBagnon()   -- (in case Bagnon loaded before this file)
if hooksecurefunc then
    for _, fn in ipairs({ "ContainerFrame_Update", "ContainerFrame_GenerateFrame", "OpenBag", "ToggleBag",
                          "OpenAllBags", "ToggleAllBags", "OpenBackpack", "ToggleBackpack" }) do
        if _G[fn] then hooksecurefunc(fn, UpdateSoon) end
    end
    -- modern bag windows redraw their slots through a mixin method rather than a global function
    local function HookMixin(f)
        if f and f.UpdateItems then hooksecurefunc(f, "UpdateItems", UpdateSoon) end
    end
    for i = 1, 13 do HookMixin(_G["ContainerFrame" .. i]) end
    HookMixin(_G.ContainerFrameCombinedBags)
end

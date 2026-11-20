-- P13Tweaks feature: hover the profession window's "Create All" button to see how long the whole batch will take.
-- Time = number of crafts the button would make x the recipe's cast time (read from the recipe spell).
-- Uses the modern profession window (ProfessionsFrame), which loads on demand with Blizzard_Professions.
local ADDON_NAME, ns = ...

ns:RegisterOption({
    key = "craftTime",
    type = "toggle",
    label = "Show how long \"Create All\" will take",
    tooltip = "Hover the Create All button in a profession window (Cooking etc.) and the tooltip shows how many crafts it will make and the total time, based on the recipe's cast time. Changing the Quantity box does not change what Create All does, so the time follows the number of crafts you can make from your bags.",
    default = true,
})

local function FormatTime(sec)
    sec = math.floor(sec + 0.5)
    if sec < 60 then return sec .. " sec" end
    local m, s = math.floor(sec / 60), sec % 60
    if m < 60 then return s > 0 and ("%d min %d sec"):format(m, s) or (m .. " min") end
    local h = math.floor(m / 60)
    return ("%d hr %d min"):format(h, m % 60)
end

-- Cast time of a recipe in seconds (nil if the client doesn't report one).
local function CastSeconds(recipeID)
    local ms
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(recipeID)
        ms = info and info.castTime
    elseif GetSpellInfo then
        ms = select(4, GetSpellInfo(recipeID))
    end
    if ms and ms > 0 then return ms / 1000 end
end

local function CurrentRecipe(page)
    local form = page and page.SchematicForm
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    return info and info.recipeID, info
end

local function AddTimeLine(button)
    if not ns:Get("craftTime") then return end
    local page = button:GetParent()
    local recipeID, info = CurrentRecipe(page)
    if not recipeID then return end
    -- how many crafts "Create All" will make
    local count = page.GetCraftableCount and page:GetCraftableCount()
    if not count or count <= 0 then
        local fresh = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
        count = (fresh and fresh.numAvailable) or (info and info.numAvailable) or 0
    end
    if count <= 0 then return end
    local cast = CastSeconds(recipeID)
    if not cast then return end
    GameTooltip:AddLine(("%d crafts x %.1f sec = |cff33ff99%s|r"):format(count, cast, FormatTime(count * cast)), 1, 1, 1)
    GameTooltip:Show()
end

local hooked = false
local function Hook()
    if hooked then return end
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local btn = page and page.CreateAllButton
    if not btn then return end
    hooked = true
    btn:HookScript("OnEnter", function(self)
        -- the game's own OnEnter only shows a tooltip when the button is disabled, so make sure one is up
        if not GameTooltip:IsOwned(self) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Create All", 1, 1, 1)
        end
        AddTimeLine(self)
    end)
    btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("TRADE_SKILL_SHOW")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 ~= "Blizzard_Professions" then return end
    -- the frame is built just after the addon loads, so try again on the next frame too
    Hook()
    C_Timer.After(0, Hook)
end)
if ProfessionsFrame then Hook() end

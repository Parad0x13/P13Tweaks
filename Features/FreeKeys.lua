-- P13Tweaks feature: which keys have nothing bound to them, so you know what's free to use
-- (e.g. for Scrap's "Toggle Item Under Mouse"). /p13 freekeys lists them by modifier; the
-- options window shows the plain (no-modifier) ones.
local ADDON_NAME, ns = ...

-- Keys worth offering, in keyboard order. (Binding names as the game writes them.)
local KEYS = {}
for _, k in ipairs({ "`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=" }) do table.insert(KEYS, k) end
for c in ("QWERTYUIOP"):gmatch(".") do table.insert(KEYS, c) end
for _, k in ipairs({ "[", "]", "\\" }) do table.insert(KEYS, k) end
for c in ("ASDFGHJKL"):gmatch(".") do table.insert(KEYS, c) end
for _, k in ipairs({ ";", "'" }) do table.insert(KEYS, k) end
for c in ("ZXCVBNM"):gmatch(".") do table.insert(KEYS, c) end
for _, k in ipairs({ ",", ".", "/" }) do table.insert(KEYS, k) end
for i = 1, 12 do table.insert(KEYS, "F" .. i) end
for _, k in ipairs({ "INSERT", "DELETE", "HOME", "END", "PAGEUP", "PAGEDOWN" }) do table.insert(KEYS, k) end
for i = 0, 9 do table.insert(KEYS, "NUMPAD" .. i) end
for _, k in ipairs({ "NUMPADPLUS", "NUMPADMINUS", "NUMPADMULTIPLY", "NUMPADDIVIDE", "NUMPADDECIMAL",
    "BUTTON3", "BUTTON4", "BUTTON5", "MOUSEWHEELUP", "MOUSEWHEELDOWN" }) do table.insert(KEYS, k) end

local MODIFIERS = { { "", "No modifier" }, { "SHIFT-", "Shift" }, { "CTRL-", "Ctrl" }, { "ALT-", "Alt" } }

-- Friendlier names for a few keys.
local PRETTY = {
    BUTTON3 = "Middle mouse", BUTTON4 = "Mouse 4", BUTTON5 = "Mouse 5",
    MOUSEWHEELUP = "Wheel up", MOUSEWHEELDOWN = "Wheel down",
    NUMPADPLUS = "Num+", NUMPADMINUS = "Num-", NUMPADMULTIPLY = "Num*", NUMPADDIVIDE = "Num/",
    NUMPADDECIMAL = "Num.", PAGEUP = "PgUp", PAGEDOWN = "PgDn", INSERT = "Ins", DELETE = "Del",
}
local function Pretty(k)
    return PRETTY[k] or k:gsub("^NUMPAD", "Num")
end

-- Free keys for one modifier prefix ("" / "SHIFT-" ...), as display names.
local function FreeKeys(prefix)
    local list = {}
    if not GetBindingAction then return list end
    for _, k in ipairs(KEYS) do
        local action = GetBindingAction(prefix .. k, true)   -- true: count addon overrides too
        if not action or action == "" then table.insert(list, (Pretty(k))) end
    end
    return list
end

ns:RegisterOption({
    key = "freeKeysInfo",
    type = "info",
    label = "Free keys",
    getText = function()
        local free = FreeKeys("")
        return "Keys with nothing bound (no modifier): " .. (#free > 0 and table.concat(free, " ") or "none")
            .. "\n/p13 freekeys also lists the free Shift / Ctrl / Alt ones."
    end,
})

ns:RegisterCommand("freekeys", "list keys with nothing bound to them (free to use)", function()
    ns:Print("Keys with nothing bound to them:")
    for _, m in ipairs(MODIFIERS) do
        local free = FreeKeys(m[1])
        ns:Print(("|cffffd200%s:|r %s"):format(m[2], #free > 0 and table.concat(free, "  ") or "none"))
    end
    ns:Print("Bind one in Options > Keybindings (Scrap's is under AddOns > Scrap).")
end)

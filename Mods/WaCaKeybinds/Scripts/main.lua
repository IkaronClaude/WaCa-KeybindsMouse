-- WaCa Keybinds & Mouse: PC controls for the game - rebind any key (config/keybinds.ini [Actions] / [Axes], applied by
-- WaCa Core's native half when the game builds its bindings), a real MOUSE (the cursor in menus, clicking the menus'
-- buttons, mouse look in gameplay), key aliases, Space / click to advance dialogue, and the menus' own keys + icons.
-- Needs WaCa Core.
local VERSION = "1.0.0"
local WaCa = require("WaCa")

local modDir = debug.getinfo(1, "S").source:match("^@(.+)[/\\]Scripts[/\\]main%.lua$") or "."
local function log(fmt, ...) print(string.format("[WaCaKeybinds] " .. fmt .. "\n", ...)) end
log("%s loaded", VERSION)
if not WaCaNative_Command then
    log("WaCa Core is not installed (or off) - this mod needs it: nothing applied")
    return
end

local Menus = require("menus")

-- Key aliases ([KeyAliases] Key = OtherKey[, ...]): pressing Key also presses OtherKey. The game's menus read raw keys
-- (SwtPlayerController.OnKeyPressed / OnKeyReleased) rather than bindings - many use BackSpace as "back" - so
-- "Escape = BackSpace" makes Escape work as back in menus too.
local aliases = {}
local dialogueAliases = {}
local function readAliases(ini, section)
    local out = {}
    for _, k in ipairs(ini and ini[section] and ini[section].__order or {}) do
        local targets = {}
        for t in ini[section][k]:gmatch("[^,%s]+") do table.insert(targets, t) end
        out[k] = targets
    end
    return out
end
local ini = WaCa.ReadIni(modDir .. "/config/keybinds.ini")
aliases = readAliases(ini, "KeyAliases")
dialogueAliases = readAliases(ini, "DialogueKeyAliases")

-- Dialogue keys ([DialogueKeyAliases] Key = OtherKey): while a conversation is on screen, pressing Key also presses
-- OtherKey as a real key press - SpaceBar = Enter: Space advances / confirms dialogue like Enter does (operator
-- 2026-10-25; a left click too, operator 2026-10-27 - but not while answer choices show: the click picks one itself). A
-- conversation is the game's QuestGiverWidget (its "next" prompt is Button_Confirm = Enter); it is looked up when such
-- a key is pressed, not tracked.
local function dialogueUp()
    for _, w in ipairs(FindAllOf("QuestGiverWidget") or {}) do
        if w:IsValid() and w:IsInViewport() and w:IsVisible() then return w end
    end
    return nil
end
-- a click advances only a line the game itself offers to advance - its "next" prompt (mcGuiNext) shown; answer
-- choices without it are left to the click (it picks one). Shown = it and every container above it visible. (The
-- answer buttons can't tell: a plain line shows button 1 too - VM 2026-10-27.)
local function shown(widget)
    local w, guard = widget, 0
    while w and w:IsValid() and guard < 32 do
        if not w:IsVisible() then return false end
        local ok, parent = pcall(function() return w:GetParent() end)
        w = ok and parent or nil
        guard = guard + 1
    end
    return true
end
local function choicesUp(w)
    local ok, next = pcall(function() return shown(w.mcGuiNext) end)
    return not (ok and next)
end
WaCa.On("KeyDown", function(_, name)
    local targets = dialogueAliases[name]
    local widget = targets and dialogueUp()
    if not widget then return end
    if name:find("MouseButton") and choicesUp(widget) then
        log("dialogue: %s on answer choices (no next prompt) - the click picks one itself", name)
        return
    end
    for _, target in ipairs(targets) do
        if not dialogueAliases[target] then
            log("dialogue: %s -> %s", name, target)
            WaCa.Command("PressKey|" .. target)
        end
    end
end)

-- An alias posts a REAL key press of its target to the game window (native PressKey): menus only react to real input
-- - calling the controller's OnKeyPressed with the target never reached them (Escape did nothing, operator
-- 2026-10-25). Presses come from the raw KeyDown event (the window's own key messages, before the game routes them -
-- so a paused game or a key bound to nothing still counts). A target that is itself aliased is skipped (no loops).
WaCa.On("KeyDown", function(_, name)
    -- only in menus: in gameplay Escape is the game's pause key - a BackSpace with it reached the pause menu while it
    -- was being built and crashed the game (VM, 2026-10-25)
    if not aliases[name] or not Menus.InMenu() then return end
    for _, target in ipairs(aliases[name] or {}) do
        if not aliases[target] then WaCa.Command("PressKey|" .. target) end
    end
end)
local n = 0
for _ in pairs(aliases) do n = n + 1 end
log("%d key aliases", n)

-- Menu keys ([UIKeys] Row = Key): the menus' own keyboard keys and hint icons ([UIIcons])
local function applyUIKeys()
    local keys, icons = ini and ini["UIKeys"], ini and ini["UIIcons"]
    for _, row in ipairs(keys and keys.__order or {}) do
        if not WaCa.SetUIKey(row, keys[row]) then log("menu key %s: the key table is not loaded", row) end
    end
    for _, row in ipairs(icons and icons.__order or {}) do
        if not WaCa.SetUIIcon(row, icons[row]) then log("menu icon %s: no icon for %s", row, icons[row]) end
    end
    log("%d menu keys, %d menu icons set", keys and #keys.__order or 0, icons and #icons.__order or 0)
end
-- (the game's tables are loaded by the time a screen shows with text - the first screens are the splash)
local uiKeysApplied = false
WaCa.On("ScreenShown", function()
    if uiKeysApplied or not WaCa.IsTextReady() then return end
    uiKeysApplied = true
    applyUIKeys()
end)

-- the mouse: the cursor in menus, clicks on the menus' buttons, mouse look and camera-relative movement ([Mouse])
Menus.Init({ WaCa = WaCa, log = log, modDir = modDir })

WaCa.Ready()

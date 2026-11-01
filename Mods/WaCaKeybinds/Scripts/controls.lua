-- THE CONTROLS MENU: rebind keys in the game. The game ships a "Control Configuration" popup
-- (WBP_GuiPopupControlConfig: every command's gamepad and keyboard key, a "Reset Default" button) that nothing in the
-- game opens. Enter or a click on the pause menu's CONTROLS page opens it here, as a rebinding screen:
--   Up / Down (or the mouse) pick a keyboard key; Enter / a click = "press the new key"; the next key press binds it
--   (Escape cancels, Delete gives the command the game's own key back); "Reset Default" gives every command on the
--   screen its game key back; Escape closes.
-- A binding is written to keybinds.ini [Actions] - the one source, the file you can still edit by hand - and applied
-- to the live bindings at once (WaCa Core's ApplyBindings). Nothing of the game's is changed: the popup is the game's
-- own widget, its key icons the game's own (it reads the live bindings). While it is open the game gets no keys or
-- clicks (WaCa Core's SwallowAll): the pause menu under it stays as it was.
-- keybinds.ini [ControlsMenu] On = 0 turns it off.
local Controls = {}

local WaCa, log, modDir, iniPath, Menus

local POPUP_CLASS = "/Game/Art/UXD/Blueprints/Popups/WBP_GuiPopupControlConfig.WBP_GuiPopupControlConfig_C"
local KEY_BUTTON = "WBP_GuiButtonControlKeyConfiguration_C"
local PAUSE_CONTROLS = "WBP_GuiPauseControllerPC_C"
-- ESlateVisibility
local VISIBLE, COLLAPSED, HIDDEN, SELF_HIT_TEST_INVISIBLE = 0, 1, 2, 4

local popup = nil          -- the open popup
local rows = {}            -- { button, command (the engine action name) } top to bottom; the last may be the reset
local sel = 1
local waiting = false      -- the selected row waits for its new key
local commandNames = nil   -- ECommands value -> name
local status = nil         -- the popup's hint / result line (a text block of ours in its tree)
local modKeys = {}         -- "<mod>.<name>" -> { mod, name, key, label }: every mod's own keys (WaCa.ModKey)
local HINT = "Enter: change the key    Delete: the game's key    Esc: back"

local function valid(o) return o ~= nil and pcall(function() return o:IsValid() end) and o:IsValid() end
local function isOpen() return valid(popup) end

local function commandName(value)
    if not commandNames then
        commandNames = {}
        local enum = StaticFindObject("/Script/SwtEngine.ECommands")
        if valid(enum) then
            enum:ForEachName(function(n, v) commandNames[v] = (n:ToString():gsub("^.*::", "")) end)
        end
    end
    return commandNames[value]
end

-- the widget, every container above it and the user widgets holding them visible, the outermost in the viewport
local function onScreen(widget)
    local w, guard, last = widget, 0, nil
    while valid(w) and guard < 48 do
        if not w:IsVisible() then return false end
        last = w
        local ok, parent = pcall(function() return w:GetParent() end)
        if not (ok and valid(parent)) then
            -- (a user widget's root has no parent: the user widget is the tree's outer's outer)
            ok, parent = pcall(function()
                local tree = w:GetOuter()
                local owner = tree and tree:GetOuter()
                return owner and owner:IsA(StaticFindObject("/Script/UMG.UserWidget")) and owner or nil
            end)
            if not (ok and valid(parent)) then break end
        end
        w = parent
        guard = guard + 1
    end
    local ok, inView = pcall(function() return last:IsInViewport() end)
    return ok and inView
end

-- the pause menu's CONTROLS page is on screen (a live one: the class's own template copies are not)
local function pausePageUp()
    for _, w in ipairs(FindAllOf(PAUSE_CONTROLS) or {}) do
        local ok, up = pcall(function() return w:GetFullName():find("/Engine/Transient", 1, true) ~= nil and onScreen(w) end)
        if ok and up then return true end
    end
    return false
end

---------------------------------------------------------------------------------------------------------------------
-- keybinds.ini: one key of one section rewritten in place - the comments, the order and every other line stay

local function setIniKey(section, key, value)
    local f = io.open(iniPath, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    local nl = text:find("\r\n", 1, true) and "\r\n" or "\n"
    local lines = {}
    for line in (text:gsub("\r\n", "\n") .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    local inSection, sectionAt, done = false, nil, false
    local out = {}
    for _, line in ipairs(lines) do
        local name = line:match("^%s*%[(.-)%]%s*$")
        if name then
            if inSection and not done and value then
                -- (the key wasn't there: at the end of its section, before the blank lines)
                local at = #out
                while at > 0 and not out[at]:match("%S") do at = at - 1 end
                table.insert(out, at + 1, key .. " = " .. value)
                done = true
            end
            inSection = name == section
            if inSection then sectionAt = #out + 1 end
            out[#out + 1] = line
        elseif inSection and not done and line:match("^%s*" .. key:gsub("%p", "%%%0") .. "%s*=") then
            if value then out[#out + 1] = key .. " = " .. value end
            done = true
        else
            out[#out + 1] = line
        end
    end
    if inSection and not done and value then
        local at = #out
        while at > 0 and not out[at]:match("%S") do at = at - 1 end
        table.insert(out, at + 1, key .. " = " .. value)
        done = true
    end
    if not sectionAt and value then
        out[#out + 1] = ""
        out[#out + 1] = "[" .. section .. "]"
        out[#out + 1] = key .. " = " .. value
    end
    f = io.open(iniPath, "w")
    if not f then return false end
    f:write(table.concat(out, nl), nl)
    f:close()
    return true
end

-- the command's keys in keybinds.ini [Actions] (nil = the game's own)
local function iniKeys(command)
    local ini = WaCa.ReadIni(iniPath) or {}
    local v = ini["Actions"] and ini["Actions"][command]
    if not v then return nil end
    local keys = {}
    for k in v:gmatch("[^,%s]+") do keys[#keys + 1] = k end
    return keys
end

local function isMouse(key) return key:find("Mouse") ~= nil end

---------------------------------------------------------------------------------------------------------------------
-- the popup

local function selectCanvas(row, on)
    local b = row.button
    pcall(function()
        b.CanvasSelected:SetVisibility(on and SELF_HIT_TEST_INVISIBLE or HIDDEN)
        b.CanvasNormal:SetVisibility(on and HIDDEN or SELF_HIT_TEST_INVISIBLE)
    end)
end

-- the key icons again, from the live bindings (the game's own lookup: each key button's OnSetupInputs) - only on
-- buttons on screen: the class's template copies have no child widgets, and OnSetupInputs on one read a null and
-- crashed the game (VM 2026-11-01); pcall can't catch that
local function refreshIcons()
    for _, b in ipairs(FindAllOf(KEY_BUTTON) or {}) do
        local ok, live = pcall(function() return b:GetFullName():find("/Engine/Transient", 1, true) ~= nil and onScreen(b) end)
        if ok and live then pcall(function() b:OnSetupInputs() end) end
    end
end

local function setStatus(text)
    if valid(status) then pcall(function() status:SetText(FText(text)) end) end
end

local function showRow(i)
    for j, row in ipairs(rows) do selectCanvas(row, j == i) end
    sel = i
end

local function split(list)
    local out = {}
    for k in tostring(list or ""):gmatch("[^,%s]+") do out[#out + 1] = k end
    return out
end

-- who else answers to this key: the other commands on the screen (their keys as they are now - WaCa Core), and every
-- mod's own keys
local function clashes(row, key)
    local out = {}
    for _, other in ipairs(rows) do
        if other.command and other ~= row and WaCaNative_BoundKeys then
            for _, k in ipairs(split(WaCaNative_BoundKeys(other.command))) do
                if k == key then out[#out + 1] = (other.label or other.command) end
            end
        end
    end
    for _, e in pairs(modKeys) do
        -- ("ClanLife" said as "Clan Life")
        if e.key == key then out[#out + 1] = string.format("%s's key to %s", (e.mod:gsub("(%l)(%u)", "%1 %2")), e.label) end
    end
    return out
end

-- while a row waits: its key icon hidden - the highlighted empty slot is the "press a key"
local function showWaiting(on)
    local row = rows[sel]
    if not row or not row.command then return end
    pcall(function()
        row.button.mcGuiKeyNormal:SetVisibility(on and HIDDEN or SELF_HIT_TEST_INVISIBLE)
        row.button.mcGuiKeySelect:SetVisibility(on and HIDDEN or SELF_HIT_TEST_INVISIBLE)
    end)
    waiting = on
end

local function apply()
    WaCa.Command("ApplyBindings")
    refreshIcons()
end

local function bind(row, key)
    -- the new key replaces the command's keyboard keys; its mouse buttons stay (Interact = E, LeftMouseButton)
    local keys = { key }
    for _, k in ipairs(iniKeys(row.command) or {}) do
        if isMouse(k) and k ~= key then keys[#keys + 1] = k end
    end
    -- the same key elsewhere: both answer to it - said, not refused (the game's own defaults share keys between
    -- commands that never meet: Drop / Friend_Talk = C)
    local also = clashes(row, key)
    setIniKey("Actions", row.command, table.concat(keys, ", "))
    log("controls menu: %s = %s (keybinds.ini [Actions])%s", row.command, table.concat(keys, ", "),
        #also > 0 and (" - also " .. table.concat(also, ", ")) or "")
    apply()
    if #also > 0 then
        setStatus(string.format("%s is %s now - it is also %s", key, row.label or row.command, table.concat(also, ", ")))
    else
        setStatus(string.format("%s is %s now", key, row.label or row.command))
    end
end

-- the game's own keys back ("Default" - WaCa Core puts the game's keys there); its mouse buttons stay (Interact on a
-- click), else the line goes
local function restore(row)
    local mouse = {}
    for _, k in ipairs(iniKeys(row.command) or {}) do
        if isMouse(k) then mouse[#mouse + 1] = k end
    end
    setIniKey("Actions", row.command, #mouse > 0 and ("Default, " .. table.concat(mouse, ", ")) or nil)
end

local function unbind(row)
    restore(row)
    log("controls menu: %s back to the game's key", row.command)
    apply()
    setStatus(string.format("%s: the game's key again", row.label or row.command))
end

local function resetAll()
    for _, row in ipairs(rows) do
        if row.command and iniKeys(row.command) then restore(row) end
    end
    log("controls menu: every command on the screen back to the game's keys")
    apply()
    setStatus("Every key on the screen is the game's own again")
end

local function close()
    if valid(popup) then pcall(function() popup:RemoveFromParent() end) end
    popup, rows, waiting, status = nil, {}, false, nil
    WaCa.Command("SwallowAll|0")
    log("controls menu: closed")
end

-- the popup's keyboard key buttons (its gamepad ones are left as they are), top to bottom, then "Reset Default"
local function collectRows(w)
    local tree = w.WidgetTree:GetFullName():gsub("^%S+ ", "")
    local found = {}
    for _, b in ipairs(FindAllOf(KEY_BUTTON) or {}) do
        pcall(function()
            if b:GetOuter():GetFullName():gsub("^%S+ ", "") == tree and b.PcOrConsoles == 0 then
                local name = commandName(b.ActionCommand)
                local _, top = WaCa.WidgetRect(b)
                if name then found[#found + 1] = { button = b, command = name, top = top or 0 } end
            end
        end)
    end
    table.sort(found, function(a, b) return a.top < b.top end)
    -- each row's name as the screen shows it ("INTERACT"): the popup's text on the row's line, left of its keys
    local texts = {}
    for _, t in ipairs(FindAllOf("TextBlock") or {}) do
        pcall(function()
            if t:GetOuter():GetFullName():gsub("^%S+ ", "") == tree then
                local l, top, r, b = WaCa.WidgetRect(t)
                if l then texts[#texts + 1] = { text = t, l = l, r = r, mid = (top + b) / 2 } end
            end
        end)
    end
    for _, row in ipairs(found) do
        local l, top, _, b = WaCa.WidgetRect(row.button)
        if l then
            local best, bestD = nil, (b - top)
            for _, t in ipairs(texts) do
                local d = math.abs(t.mid - (top + b) / 2)
                if t.r < l and d < bestD then best, bestD = t, d end
            end
            if best then
                row.labelText = best.text
                pcall(function() row.label = best.text:GetText():ToString() end)
            end
        end
    end
    local ok, err = pcall(function()
        local r = w.mcGuiButtonRestore
        if not valid(r) then error("no mcGuiButtonRestore") end
        r:SetVisibility(VISIBLE)
        found[#found + 1] = { button = r, reset = true }
    end)
    if not ok then log("controls menu: no Reset Default row (%s)", tostring(err)) end
    return found
end

-- the hint / result line: a text block of ours at the popup's foot, in the font of its row names
local function makeStatus(w, list)
    local ok, t = pcall(function()
        local root = w.WidgetTree.RootWidget
        local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), w.WidgetTree, FName("WaCaControlsStatus"))
        local slot = root:AddChildToCanvas(t)
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 1 }, Maximum = { X = 0.5, Y = 1 } })
        slot:SetAlignment({ X = 0.5, Y = 1 })
        slot:SetPosition({ X = 0, Y = -20 })
        slot:SetAutoSize(true)
        pcall(function() t:SetJustification(1) end)
        for _, row in ipairs(list) do
            if valid(row.labelText) then
                pcall(function() t:SetFont(row.labelText.Font) end)
                pcall(function() t:SetColorAndOpacity(row.labelText.ColorAndOpacity) end)
                break
            end
        end
        return t
    end)
    if not ok then log("controls menu: no hint line (%s)", tostring(t)) return nil end
    return t
end

local function open()
    if isOpen() then return end
    local cls = StaticFindObject(POPUP_CLASS)
    if not valid(cls) then
        log("controls menu: the game's popup class is not loaded (%s)", POPUP_CLASS)
        return
    end
    local pc = nil
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player then pc = c break end
    end
    local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not valid(w) then
        log("controls menu: the popup could not be created")
        return
    end
    w:AddToViewport(500)
    popup = w
    -- (every mod's keys again: what was announced while the mods loaded may not have arrived)
    WaCa.Emit("keys.ask")
    WaCa.Command("SwallowAll|1")
    -- (the rows' places are known once it is drawn)
    ExecuteInGameThreadWithDelay(200, function()
        if popup ~= w or not valid(w) then return end
        rows = collectRows(w)
        local list = {}
        for _, row in ipairs(rows) do list[#list + 1] = row.command or "Reset Default" end
        log("controls menu: open - %s", table.concat(list, ", "))
        status = makeStatus(w, rows)
        setStatus(HINT)
        showRow(1)
    end)
end

local function rowUnderMouse()
    if not WaCaNative_CursorPos then return nil end
    local x, y = WaCaNative_CursorPos()
    for i, row in ipairs(rows) do
        local l, t, r, b = WaCa.WidgetRect(row.button)
        if l and x >= l - 8 and x < r + 8 and y >= t - 4 and y < b + 4 then return i end
    end
    return nil
end

local function activate()
    local row = rows[sel]
    if not row then return end
    if row.reset then resetAll() return end
    showWaiting(true)
    setStatus(string.format("Press the new key for %s    (Esc: cancel    Delete: the game's key)", row.label or row.command))
    log("controls menu: press the new key for %s (Escape cancels, Delete = the game's key)", row.command)
end

local function onKey(key)
    if not isOpen() then
        if (key == "Enter" or key == "LeftMouseButton") and pausePageUp() then open() end
        return
    end
    if #rows == 0 then return end
    if waiting then
        if key == "LeftMouseButton" then return end      -- (a click is how a row is picked, not a binding)
        local row = rows[sel]
        showWaiting(false)
        if key == "Escape" then
            log("controls menu: %s unchanged", row.command)
            setStatus(HINT)
        elseif key == "Delete" then
            unbind(row)
        else
            bind(row, key)
        end
        return
    end
    if key == "Escape" or key == "BackSpace" then
        close()
    elseif key == "Up" or key == "W" then
        showRow(sel > 1 and sel - 1 or #rows)
    elseif key == "Down" or key == "S" then
        showRow(sel < #rows and sel + 1 or 1)
    elseif key == "Enter" or key == "SpaceBar" or key == "E" then
        activate()
    elseif key == "Delete" and rows[sel] and rows[sel].command then
        unbind(rows[sel])
    elseif key == "LeftMouseButton" then
        local i = rowUnderMouse()
        if i then showRow(i) activate() end
    end
end

function Controls.Init(c)
    WaCa, log, modDir, Menus = c.WaCa, c.log, c.modDir, c.Menus
    iniPath = modDir .. "/config/keybinds.ini"
    local ini = WaCa.ReadIni(iniPath) or {}
    if ((ini["ControlsMenu"] or {}).On or "1") == "0" then return end
    -- a screen left over from before a reload of this mod: gone (on the game thread - this runs on the loader's),
    -- its keys back
    WaCa.Command("SwallowAll|0")
    ExecuteInGameThread(function()
        for _, w in ipairs(FindAllOf("WBP_GuiPopupControlConfig_C") or {}) do
            pcall(function()
                if w:GetFullName():find("/Engine/Transient", 1, true) and w:IsInViewport() then
                    w:RemoveFromParent()
                    log("controls menu: one left open before a reload - closed")
                end
            end)
        end
    end)
    Menus.Hold(isOpen)
    -- every mod's own keys (WaCa.ModKey) - announced as they load; the ones that loaded first announce again
    WaCa.On("keys.mod", function(e)
        if type(e) == "table" and e.mod and e.name then modKeys[e.mod .. "." .. e.name] = e end
    end)
    WaCa.Emit("keys.ask")
    WaCa.On("KeyDown", function(_, key) ExecuteInGameThread(function() onKey(key) end) end)
    WaCa.On("MouseMove", function()
        if not isOpen() or waiting then return end
        ExecuteInGameThread(function()
            local i = rowUnderMouse()
            if i and i ~= sel then showRow(i) end
        end)
    end)
    -- the pause menu went (a cutscene, a load): the popup goes with it
    WaCa.On("ScreenHidden", function()
        if not isOpen() then return end
        ExecuteInGameThreadWithDelay(100, function()
            if isOpen() and not pausePageUp() then close() end
        end)
    end)
end

Controls.IsOpen = isOpen
return Controls

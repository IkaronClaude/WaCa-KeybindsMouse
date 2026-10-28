-- The mouse cursor in menus: the game hides it everywhere (a console-style UI); it shows while any menu is up and
-- hides again in gameplay (mouse look). A "menu" = any screen up that is not the gameplay screen or a HUD, or a popup
-- on the gameplay screen (the pause menu, the map, ...). Decided whenever a screen comes or goes (the ScreenShown /
-- ScreenHidden events) and when keyboard focus moves between screens. config/keybinds.ini [Mouse] MenuCursor = 0
-- turns it off.
local Menus = {}

local WaCa, log, modDir

-- true while a menu is showing, false in gameplay, nil while no screen is up (WaCa.MenuShowing: shared by every WaCa
-- mod - the same answer the clan loop pauses on)
local function menuShowing(leaving) return WaCa.MenuShowing(leaving) end

local enabled = true
local shown = nil
-- Gameplay's mouse capture: PC-style mouse look, the mouse captured as soon as the game viewport has focus (EMouseCapture
-- CapturePermanently = 1). Not the game's own mode: that is "capture while a button is held" - drag to look, which the
-- operator called a regression (2026-10-25); and "capture on the first click" (2) left no mouse control at all.
-- keybinds.ini [Mouse] GameplayCapture overrides it (0 none, 1 permanent, 2 permanent from the first click, 3 while a
-- button is held, 4 while the right button is held).
local gameplayCapture = 1

-- bShowMouseCursor alone shows nothing (operator 2026-10-25): the game viewport keeps the mouse captured with the
-- cursor hidden during capture, and the cursor type may be None. A menu gets "game and UI" input with the cursor kept
-- visible and the Default cursor; gameplay gets the game's "game only" mode back (mouse look captures the mouse).
local function applyCursor(c, want, transition)
    if c.bShowMouseCursor ~= want then c.bShowMouseCursor = want end
    if c.bEnableClickEvents ~= want then c.bEnableClickEvents = want end
    if c.bEnableMouseOverEvents ~= want then c.bEnableMouseOverEvents = want end
    if want and c.CurrentMouseCursor ~= 1 then c.CurrentMouseCursor = 1 end      -- EMouseCursor::Default
    if not transition then return end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok, err
    if want then
        -- (player controller, widget to focus, mouse lock: DoNotLock, hide the cursor during capture: no, flush input)
        ok, err = pcall(function() lib:SetInputMode_GameAndUIEx(c, nil, 0, false, false) end)
    else
        ok, err = pcall(function() lib:SetInputMode_GameOnly(c, false) end)
    end
    if not ok then log("mouse cursor: input mode: %s", tostring(err)) end
    -- no capture in menus (a click would capture the mouse and hide the cursor); gameplay's capture back in gameplay,
    -- with the viewport focused so it takes the mouse at once. Set AFTER the input mode, which resets it
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok0, err0 = pcall(function()
        statics:SetViewportMouseCaptureMode(c, want and 0 or gameplayCapture)
        if not want then lib:SetFocusToGameViewport() end
    end)
    if not ok0 then log("mouse cursor: capture mode: %s", tostring(err0)) end
end

-- the cursor for the screens up now. full: also the input mode + mouse capture, not only on a menu <-> gameplay change
-- - a screen's own Construct can set them back (a click in a menu then captured the mouse and hid the cursor instead
-- of reaching the button: operator 2026-10-25). Never on focus changes: setting the input mode moves the keyboard
-- focus (it would pull the keyboard out of the name box).
-- No screen up is either the gap between two screens (a frame or two) or gameplay (the game shows no screen there at
-- all - the cursor stayed in menu mode for a whole session, no mouse look: operator 2026-10-25). It is settled once,
-- shortly after: a screen by then = it was a gap, still none = gameplay.
local SETTLE_MS = 150
local settling = false
local update

local function settle()
    settling = false
    local want = menuShowing(nil)
    if want == nil then want = false end
    update(nil, true, want)
end

update = function(leaving, full, decided)
    if not enabled then return end
    local want = decided
    if want == nil then want = menuShowing(leaving) end
    if want == nil then
        if not settling then
            settling = true
            ExecuteInGameThreadWithDelay(SETTLE_MS, settle)
        end
        return
    end
    local transition = want ~= shown
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player and c.Player:IsValid() then applyCursor(c, want, transition or (full and want)) end
    end
    if not transition then return end
    -- the first decision is only logged when it shows the cursor (at start-up the game's own state is "hidden")
    if shown ~= nil or want then log("mouse cursor %s", want and "shown (menu)" or "hidden (gameplay)") end
    shown = want
    Menus.MouseLook(not want)
end

-- Mouse look (native camera.cpp): the mouse turns the game's camera directly, in gameplay only - in a menu it moves
-- the cursor. Sensitivity: keybinds.ini [Mouse] LookYaw / LookPitch (degrees per mouse unit)
local look = { yaw = 2.0, pitch = 1.5, on = nil }
function Menus.MouseLook(on)
    if gameplayCapture == 0 then on = false end
    if look.on == on then return end
    look.on = on
    WaCa.Command(string.format("MouseLook|%d|%.4f|%.4f", on and 1 or 0, look.yaw, look.pitch))
end

-- Mouse clicks on the game's own menu buttons. Every button control carries a UMG collision button (Slate hit-tests
-- it, so it knows when it is hovered), but on PC the game binds nothing to its click events - the click went
-- nowhere (operator 2026-10-25; read on the live main menu: OnClicked / OnPressed / OnReleased all empty). Its own
-- pointer path does work: the host's OnUIPress + OnUIRelease with the control activates it (VM test: the main menu's
-- story button opened "Select Your Cat"). So a left click in a menu presses the hovered control through its host - the
-- nearest panel or screen around it that handles UI presses.
local panelClass, screenClass

local function hostOf(control)
    panelClass = panelClass or StaticFindObject("/Script/SwtEngine.GuiPanel")
    screenClass = screenClass or StaticFindObject("/Script/SwtEngine.SwtScreen")
    local o = control:GetOuter()
    for _ = 1, 24 do
        if not o or not o:IsValid() then return nil end
        if (panelClass and o:IsA(panelClass)) or (screenClass and o:IsA(screenClass)) then return o end
        o = o:GetOuter()
    end
    return nil
end

-- The menus' controls under the mouse: every control's collision button with the control and its host. Listed when a
-- screen comes or goes (FindAllOf walks every object - too slow for each mouse move) and again when nothing listed is
-- hovered and the list is older than a second (screens fill their lists after they show: the cat grids).
local targets, targetsAt, targetsStale = {}, -1, true

-- the game control (GuiControl) a button belongs to: the nearest one around it (most buttons are a control's own
-- mcGuiButtonCollision; some screens - the pause menu - have their buttons deeper in other widgets)
local controlClass
local function controlOf(button)
    controlClass = controlClass or StaticFindObject("/Script/SwtEngine.GuiControl")
    local o = button:GetOuter()
    for _ = 1, 24 do
        if not o or not o:IsValid() then return nil end
        if controlClass and o:IsA(controlClass) then return o end
        o = o:GetOuter()
    end
    return nil
end

-- the screen a widget sits in (its outers; a control's ParentScreen field isn't always a usable object - the
-- creator's grid items, VM 2026-10-28)
local function screenOf(widget)
    screenClass = screenClass or StaticFindObject("/Script/SwtEngine.SwtScreen")
    local o = widget:GetOuter()
    for _ = 1, 24 do
        if not o or not o:IsValid() then return nil end
        if screenClass and o:IsA(screenClass) then return o end
        o = o:GetOuter()
    end
    return nil
end

local function onScreen(widget)
    local ok, up = pcall(function()
        local screen = screenOf(widget)
        return screen and screen:IsInViewport()
    end)
    return ok and up
end

-- really on screen: the widget and every panel up to its screen visible (a hidden tab's controls keep IsVisible and
-- the place they were last drawn - VM 2026-10-28: the creator's first tab answered for the pattern grid)
local function reallyShown(widget)
    local w = widget
    for _ = 1, 40 do
        if not (w and w:IsValid()) then return true end
        if not w:IsVisible() then return false end
        if screenClass and w:IsA(screenClass) then return true end
        local p = w:GetParent()
        if not (p and p:IsValid()) then
            -- (the top of a user widget's own tree: on to the user widget, in its parent's tree)
            local tree = w:GetOuter()
            p = tree and tree:IsValid() and tree:GetOuter()
        end
        w = p
    end
    return true
end

-- The menus' controls: every game control on a screen that is up, with its host - listed when a screen comes or goes
-- (FindAllOf walks every object - too slow for each mouse move) and again when nothing listed is hovered and the list
-- is older than a second (screens fill their lists after they show: the cat grids). A control is hovered when it is
-- (Slate tracks hover on every widget under the mouse: "Select Your Cat"'s slots have no button of their own) or a
-- button in it is, else when the mouse is where it was drawn (the clan crests take no mouse at all - WaCa.MouseOver).
-- GRID ITEMS (the creator's pattern / markings / colour grids: small widgets placed in a canvas, their tiles drawn
-- bigger than the widget - 12 x 4 px for a 40 px tile): their cell is the spacing to their neighbours, and their row /
-- column come from where they sit.
local targets, targetsAt, targetsStale = {}, -1, true
local byAddress = {}
local lastSummary

local function listTargets()
    targets, byAddress = {}, {}
    local function add(control, button)
        local key = control:GetAddress()
        if byAddress[key] then
            if button then table.insert(byAddress[key].buttons, button) end
            return
        end
        local host = hostOf(control)
        if not host or not onScreen(control) then return end
        local t = { control = control, host = host, buttons = { button } }
        byAddress[key] = t
        targets[#targets + 1] = t
    end
    for _, c in ipairs(FindAllOf("GuiControl") or {}) do
        if c:IsValid() then pcall(add, c, nil) end
    end
    for _, b in ipairs(FindAllOf("Button") or {}) do
        if b:IsValid() then
            local control = controlOf(b)
            if control then pcall(add, control, b) end
        end
    end
    -- grid items: small controls sharing a parent - the cell size from the spacing of their origins
    local groups = {}
    for _, t in ipairs(targets) do
        pcall(function()
            local l, top, r, b = WaCa.WidgetRect(t.control)
            if not l or (r - l >= 16 and b - top >= 16) then return end
            local parent = t.control:GetParent()
            if not (parent and parent:IsValid()) then return end
            local g = groups[parent:GetAddress()] or {}
            groups[parent:GetAddress()] = g
            g[#g + 1] = { t = t, l = l, top = top }
        end)
    end
    for _, g in pairs(groups) do
        local dx, dy
        for i = 1, #g do
            for j = 1, #g do
                local ax, ay = math.abs(g[i].l - g[j].l), math.abs(g[i].top - g[j].top)
                if ax > 2 and (not dx or ax < dx) then dx = ax end
                if ay > 2 and (not dy or ay < dy) then dy = ay end
            end
        end
        for _, e in ipairs(g) do e.t.cellW, e.t.cellH, e.t.group = dx or dy, dy or dx, g end
    end
    targetsAt, targetsStale = os.clock(), false
    local cells = 0
    for _, t in ipairs(targets) do if t.cellW then cells = cells + 1 end end
    local summary = string.format("%d controls on screen, %d of them grid cells", #targets, cells)
    if summary ~= lastSummary then
        lastSummary = summary
        log("mouse: %s", summary)
    end
end

-- where a target is on screen: its drawn rect, or its grid cell
local function rectOf(t)
    local l, top, r, b = WaCa.WidgetRect(t.control)
    if not l then return nil end
    if t.cellW and t.cellH then r, b = l + t.cellW, top + t.cellH end
    return l, top, r, b
end

local function mouseIn(t)
    if not WaCaNative_CursorPos then return false end
    local l, top, r, b = rectOf(t)
    if not l then return false end
    local x, y = WaCaNative_CursorPos()
    return x >= l and x < r and y >= top and y < b, (r - l) * (b - top)
end

-- a click that found no control: what IS under the mouse (any hovered button / user widget), for the log
local function describeMiss()
    local hits = {}
    for _, b in ipairs(FindAllOf("Button") or {}) do
        if b:IsValid() and b:IsHovered() then
            local outer = b:GetOuter()
            outer = outer and outer:IsValid() and outer:GetOuter()
            table.insert(hits, b:GetFName():ToString() .. " in " .. (outer and outer:IsValid() and outer:GetClass():GetFName():ToString() or "?"))
        end
    end
    return #hits > 0 and table.concat(hits, ", ") or "no hovered button"
end

-- does control a sit inside control b (b is one of a's outers)?
local function inside(a, b)
    local o = a:GetOuter()
    for _ = 1, 24 do
        if not o or not o:IsValid() then return false end
        if o:GetAddress() == b:GetAddress() then return true end
        o = o:GetOuter()
    end
    return false
end

-- the hovered control - the innermost one when hovered controls sit in each other; by Slate's hover first, else by
-- where the controls were drawn (the smallest one under the mouse)
local function findHovered()
    local on, drawn, drawnArea = {}, nil, nil
    for _, t in ipairs(targets) do
        local yes = false
        pcall(function()
            if not (t.control:IsValid() and reallyShown(t.control)) then return end
            if t.control:IsHovered() then yes = true end
            for _, b in ipairs(t.buttons) do if b:IsValid() and b:IsHovered() then yes = true end end
            if not yes then
                local over, area = mouseIn(t)
                if over and (not drawnArea or area < drawnArea) then drawn, drawnArea = t, area end
            end
        end)
        if yes then on[#on + 1] = t end
    end
    if #on == 0 then return drawn end
    for _, t in ipairs(on) do
        local container = false
        for _, u in ipairs(on) do
            if u ~= t and pcall(inside, u.control, t.control) and inside(u.control, t.control) then container = true break end
        end
        if not container then return t end
    end
    return on[1]
end

local function hovered()
    if targetsStale then listTargets() end
    local t = findHovered()
    if not t and os.clock() - targetsAt > 1 then
        listTargets()
        t = findHovered()
    end
    return t
end

-- the navigation a control is selected in: a scroll grid's own (the creator's pattern / colour grids keep their
-- selection there, not in their panel's), else its host's
local gridClass
local function navOf(t)
    gridClass = gridClass or StaticFindObject("/Script/SwtEngine.GuiScrollGrid")
    local o = t.control:GetOuter()
    for _ = 1, 24 do
        if not o or not o:IsValid() then break end
        if gridClass and o:IsA(gridClass) then
            local ok, nav = pcall(function() return o.GridNavigation end)
            if ok and nav and nav:IsValid() then return nav end
        end
        o = o:GetOuter()
    end
    return t.host.CurrentNav
end

local SELECTED, NORMAL = 2, 1   -- EUIControlState ST_SELECTED / ST_NORMAL
local function sameObject(a, b) return a:GetFullName() == b:GetFullName() end

-- the position of a control in a navigation's list (LinearNavigation's ControlsNavigation), or nil
local function navIndex(nav, control)
    local found
    pcall(function()
        local list = nav.ControlsNavigation
        for i = 1, #list do
            local c = list[i]
            if c and c:IsValid() and sameObject(c, control) then found = i break end
        end
    end)
    return found
end

local BUTTON_UP, BUTTON_DOWN, BUTTON_RIGHT, BUTTON_LEFT = 1, 2, 3, 4      -- ECommands
local BUTTON_SHOULDER_L, BUTTON_SHOULDER_R = 9, 10

local function controller()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player then return c end
    end
end

-- a control's cell in a grid: its grid panel slot's Row / Column (UniformGridSlot / GridSlot), else - a grid item
-- placed in a canvas - from where it sits among its neighbours; with what identifies the grid, or nil
local function cell(control)
    local ok, slot = pcall(function() return control.Slot end)
    if ok and slot and slot:IsValid() then
        local row, col
        pcall(function() row, col = slot.Row, slot.Column end)
        if type(row) == "number" and type(col) == "number" then return row, col, control:GetParent():GetAddress() end
    end
    local t = byAddress[control:GetAddress()]
    if not (t and t.group and t.cellW and t.cellH) then return nil end
    local l0, t0 = math.huge, math.huge
    for _, e in ipairs(t.group) do
        local l, top = WaCa.WidgetRect(e.t.control)
        if l then l0, t0 = math.min(l0, l), math.min(t0, top) end
    end
    local l, top = WaCa.WidgetRect(control)
    if not l then return nil end
    return math.floor((top - t0) / t.cellH + 0.5), math.floor((l - l0) / t.cellW + 0.5), t.group
end

-- THE GAME'S OWN WAY: step the selection with the screen's navigation commands (what the arrow keys / stick send)
-- until the hovered control is the selected one - the highlight, the sound and the game's state all follow (VM
-- 2026-10-28: setting the selection by hand left the old button highlighted). Lists: Up / Down, else Left / Right
-- (tabs); GRIDS (Select Your Cat, the creator's grids): the row / column difference, Down / Up and Right / Left.
local function stepGrid(t, nav, screen, pcon)
    local r1, c1, g1 = cell(nav.CurrentControl)
    local r2, c2, g2 = cell(t.control)
    if not (r1 and r2 and g1 == g2) then
        log("mouse hover: grid step - selected cell %s,%s, target %s,%s, same grid %s (current %s)", tostring(r1), tostring(c1), tostring(r2), tostring(c2),
            tostring(g1 == g2), nav.CurrentControl and nav.CurrentControl:IsValid() and nav.CurrentControl:GetFName():ToString() or "none")
        return false
    end
    local moves = {}
    for _ = 1, math.abs(r2 - r1) do moves[#moves + 1] = r2 > r1 and BUTTON_DOWN or BUTTON_UP end
    for _ = 1, math.abs(c2 - c1) do moves[#moves + 1] = c2 > c1 and BUTTON_RIGHT or BUTTON_LEFT end
    for _, m in ipairs(moves) do screen:OnListenCommand(m, 0, pcon) end
    local cur = nav.CurrentControl
    if cur and cur:IsValid() and sameObject(cur, t.control) then return true end
    local r3, c3 = cell(cur)
    return r3 == r2 and c3 == c2
end

local function stepTo(t, nav, clicked)
    local screen = screenOf(t.control) or t.host
    local from, to = navIndex(nav, nav.CurrentControl), navIndex(nav, t.control)
    if not (from and to) then return stepGrid(t, nav, screen, controller()) end
    local tries = to > from and { BUTTON_DOWN, BUTTON_RIGHT } or { BUTTON_UP, BUTTON_LEFT }
    -- (a tab bar - the pause menu's - moves with the shoulder buttons, the 1 / 2 keys: on a CLICK only - a tab turns
    -- the page, and passing over the bar with the mouse shouldn't)
    if clicked then table.insert(tries, to > from and BUTTON_SHOULDER_R or BUTTON_SHOULDER_L) end
    local pcon = controller()
    local count = #nav.ControlsNavigation
    for _, command in ipairs(tries) do
        for _ = 1, count do
            local cur = nav.CurrentControl
            if cur and cur:IsValid() and sameObject(cur, t.control) then
                return true, (command == BUTTON_SHOULDER_L or command == BUTTON_SHOULDER_R) and "tab" or nil
            end
            local before = navIndex(nav, cur)
            screen:OnListenCommand(command, 0, pcon)                  -- (IE_Pressed)
            local after = navIndex(nav, nav.CurrentControl)
            if after == before then break end                         -- (this command doesn't move this list)
        end
    end
    local cur = nav.CurrentControl
    return cur and cur:IsValid() and sameObject(cur, t.control) or false, clicked and "tab" or nil
end

-- Moves the game's own selection (the one the arrow keys move and Enter presses) to the control under the mouse. The
-- game acts on its selected control - a click on another field of "Select Your Cat" or the cat creator used the
-- selected one. Lists step there with the game's own commands; other navigations (grids) get it set directly.
local lastMissed
local function selectTarget(t, clicked)
    local nav = navOf(t)
    if not (nav and nav:IsValid()) then return false end
    local cur = nav.CurrentControl
    if cur and cur:IsValid() and sameObject(cur, t.control) then return true end
    local steppable = navIndex(nav, t.control) ~= nil or cell(t.control) ~= nil
    local stepped, why, how = pcall(stepTo, t, nav, clicked)
    if stepped and why then
        log("mouse hover: %s selected", t.control:GetFName():ToString())
        return true, how
    end
    if not stepped then log("mouse hover: stepping failed (%s)", tostring(why)) end
    -- (a list / grid the steps didn't reach: the game's own selection stays where its steps took it - setting it by hand
    -- as well split the game's state from its highlight, VM 2026-10-28)
    if steppable then
        -- (once per control: the mouse resting on a tab bar would log every move)
        local missed = t.control:GetFName():ToString()
        if missed ~= lastMissed then log("mouse hover: %s not reached by the game's steps", missed) end
        lastMissed = missed
        return false
    end
    cur = nav.CurrentControl
    local ok, err = pcall(function()
        if cur and cur:IsValid() then
            cur:OnChangeState(NORMAL)
            pcall(function() cur:OnLostFocus() end)
        end
        t.control:OnChangeState(SELECTED)
        pcall(function() t.control:OnGotFocus() end)
        nav.LastControl = cur
        nav.CurrentControl = t.control
        t.host.ControlSelected = t.control
        -- (the screen hears of it the way its navigation tells it: it updates its preview / highlight)
        pcall(function() t.host:OnNavigationChanged(nav, BUTTON_RIGHT) end)
    end)
    if ok then log("mouse hover: %s selected (set directly)", t.control:GetFName():ToString())
    else log("mouse hover: %s", tostring(err)) end
    return ok
end

local function hoverMoved()
    if shown ~= true then return end
    local t = hovered()
    if t then selectTarget(t) end
end

-- The key hint icons (the 1 / 2 tab arrows, ...): GuiActionButtonControl, each with the command it stands for. A click on
-- one presses that command's menu key ([UIKeys], else the game's own key).
local COMMANDS = { "Button_Up", "Button_Down", "Button_Right", "Button_Left", "Button_A", "Button_B", "Button_X",
    "Button_Y", "Button_ShoulderL", "Button_ShoulderR", "Button_TriggerL", "Button_TriggerR", "Button_StickL",
    "Button_StickR", "Button_StickL_Up", "Button_StickL_Down", "Button_StickL_Right", "Button_StickL_Left",
    "Button_StickR_Up", "Button_StickR_Down", "Button_StickR_Right", "Button_StickR_Left", "Button_Select",
    "Button_Start", "Button_Back", "Button_Confirm", "Button_Randomize", "Button_Skip" }
local MENU_KEYS = { Button_Up = "Up", Button_Down = "Down", Button_Right = "Right", Button_Left = "Left",
    Button_A = "Enter", Button_Confirm = "Enter", Button_B = "BackSpace", Button_Back = "BackSpace", Button_X = "E",
    Button_Y = "SpaceBar", Button_Select = "V", Button_ShoulderL = "One", Button_ShoulderR = "Two",
    Button_TriggerL = "Three", Button_TriggerR = "Four", Button_Randomize = "R", Button_Skip = "Enter" }
local uiKeys = {}

-- a menu command's keyboard key: the player's [UIKeys] setting, else the game's own keyboard table (what its menus
-- listen to), else the usual one
local function keyFor(command)
    if uiKeys[command] then return uiKeys[command] end
    local key
    pcall(function()
        local t = StaticFindObject(WaCa.UI_KEYS_TABLE)
        key = t and t:IsValid() and WaCa.UIRowKey(t, command)
    end)
    if key and key ~= "" and key ~= "None" then return key end
    return MENU_KEYS[command]
end

-- The screens' FOOTERS ("Back", "Continue", "Select" ... with their key icons): a click on an item presses its
-- command's key. Every footer widget on screen (its class named "...Footer..."); its items are the widgets it holds,
-- named after their command - CanvasContinue, CanvasBack (the C++ footers), mcGuiBaseContinue, mcGuiBackBaseSelect,
-- mcGuiBaseRemove (the Blueprint ones - VM 2026-10-28: the clan screen's Continue, the colour picker's Select). The name
-- decides: Remove, Random, then Select / Continue / Confirm / Next, then Back ("BackBaseSelect" is a Select).
local FOOTER_WORDS = { { "Remove", "Button_X" }, { "Random", "Button_Randomize" }, { "Select", "Button_A" },
    { "Continue", "Button_A" }, { "Confirm", "Button_A" }, { "Next", "Button_A" }, { "Back", "Button_B" } }

local function footerCommand(name)
    for _, w in ipairs(FOOTER_WORDS) do
        if name:find(w[1]) then return w[2] end
    end
    return nil
end

-- the widget-valued properties of an object's class and its parents: name -> true
local footerFields = {}
local function widgetFields(obj)
    local cls = obj:GetClass()
    local key = cls:GetFullName()
    if footerFields[key] then return footerFields[key] end
    local names = {}
    local s = cls
    for _ = 1, 8 do
        if not (s and s:IsValid()) then break end
        pcall(function()
            s:ForEachProperty(function(prop)
                local n = prop:GetFName():ToString()
                if footerCommand(n) then names[#names + 1] = n end
            end)
        end)
        s = s:GetSuperStruct()
    end
    footerFields[key] = names
    return names
end

-- the command of the key icon (GuiCommandButtonControl / GuiActionButtonControl) drawn inside an item of a footer,
-- or nil
local function iconCommandIn(footer, item)
    local l, t, r, b = WaCa.WidgetRect(item)
    if not l then return nil end
    for _, class in ipairs({ "GuiCommandButtonControl", "GuiActionButtonControl" }) do
        for _, w in ipairs(FindAllOf(class) or {}) do
            local found
            pcall(function()
                if not (w:IsValid() and reallyShown(w) and inside(w, footer)) then return end
                local il, it, ir, ib = WaCa.WidgetRect(w)
                if not il then return end
                local cx, cy = (il + ir) / 2, (it + ib) / 2
                if cx >= l and cx <= r and cy >= t and cy <= b then
                    local v
                    pcall(function() v = w.ButtonCommand end)
                    if type(v) ~= "number" then pcall(function() v = w.ActionCommand end) end
                    found = COMMANDS[tonumber(v) or 0]
                end
            end)
            if found then return found end
        end
    end
    return nil
end

local function clickFooter()
    for _, f in ipairs(FindAllOf("UserWidget") or {}) do
        local hit
        pcall(function()
            if not (f:IsValid() and f:GetClass():GetFName():ToString():find("Footer") and onScreen(f) and reallyShown(f)) then return end
            for _, name in ipairs(widgetFields(f)) do
                local ok, c = pcall(function() return f[name] end)
                if ok and c and c:IsValid() and reallyShown(c) and WaCa.MouseOver(c) then
                    -- the item's own key icon says which command it is (the creator's Continue isn't Enter -
                    -- VM 2026-10-28); the item's name otherwise
                    hit = iconCommandIn(f, c) or footerCommand(name)
                    return
                end
            end
        end)
        if hit then
            local key = keyFor(hit)
            log("mouse click: the footer's %s - pressing %s", hit, key)
            WaCa.Command("PressKey|" .. key)
            return true
        end
    end
    return false
end

-- The creator's CATEGORY TABS (GuiCategoryMenu: "1" < the category > "2" across the header - the key icons are plain
-- images in it): a click on its left third is the previous tab's key, on its right third the next one's
local function clickCategoryTabs()
    if not WaCaNative_CursorPos then return false end
    local x = WaCaNative_CursorPos()
    for _, m in ipairs(FindAllOf("GuiCategoryMenu") or {}) do
        local hit
        pcall(function()
            if not (m:IsValid() and onScreen(m) and reallyShown(m) and WaCa.MouseOver(m)) then return end
            local l, _, r = WaCa.WidgetRect(m)
            local f = (x - l) / math.max(1, r - l)
            if f < 0.3 then hit = "Button_ShoulderL" elseif f > 0.7 then hit = "Button_ShoulderR" end
        end)
        if hit then
            local key = keyFor(hit)
            log("mouse click: the creator's %s tab - pressing %s", hit == "Button_ShoulderL" and "previous" or "next", key)
            WaCa.Command("PressKey|" .. key)
            return true
        end
    end
    return false
end

local function clickActionIcon()
    for _, w in ipairs(FindAllOf("GuiActionButtonControl") or {}) do
        local ok, hit = pcall(function() return w:IsValid() and onScreen(w) and reallyShown(w) and WaCa.MouseOver(w) end)
        if ok and hit then
            local command = COMMANDS[tonumber(w.ActionCommand) or 0]
            local key = command and keyFor(command)
            if key then
                log("mouse click: the %s icon - pressing %s", command, key)
                WaCa.Command("PressKey|" .. key)
                return true
            end
        end
    end
    return false
end

-- THE WORLD MAP (GuiPopupWorldMap): the game pans it with held keys (W A S D) and zooms with Up / Down; its position is
-- its own (a moved layer was put back the next frame - VM 2026-10-28). So a mouse DRAG holds the pan keys the way the
-- cursor goes (the map follows the cursor), the wheel zooms. Its icons have no info of their own to show (the game's
-- "info" is the legend, on E).
local mapPan = { up = "W", down = "S", left = "A", right = "D" }
local drag                         -- { x, y, held = { key = true }, moved }

local function mapUp()
    for _, m in ipairs(FindAllOf("GuiPopupWorldMap") or {}) do
        local ok, up = pcall(function() return m:IsValid() and m:IsInViewport() end)
        if ok and up then return m end
    end
    return nil
end

local function holdPan(key, on)
    if (drag.held[key] or false) == on then return end
    drag.held[key] = on or nil
    WaCa.Command("HoldKey|" .. key .. "|" .. (on and "1" or "0"))
end

local function stopDrag()
    if not drag then return end
    for key in pairs(drag.held) do WaCa.Command("HoldKey|" .. key .. "|0") end
    drag = nil
end

local function dragMoved()
    if not drag or not WaCaNative_CursorPos then return end
    local x, y = WaCaNative_CursorPos()
    local dx, dy = x - drag.x, y - drag.y
    drag.x, drag.y = x, y
    -- the map follows the cursor: dragged right = the view goes left
    holdPan(mapPan.left, dx > 2)
    holdPan(mapPan.right, dx < -2)
    holdPan(mapPan.up, dy > 2)
    holdPan(mapPan.down, dy < -2)
    drag.moved = os.clock()
    -- (the mouse held still: the keys go)
    ExecuteInGameThreadWithDelay(150, function()
        if drag and os.clock() - drag.moved >= 0.14 then
            for key in pairs(drag.held) do holdPan(key, false) end
        end
    end)
end

local function clickHovered()
    if shown ~= true then return end
    if clickFooter() or clickCategoryTabs() or clickActionIcon() then return end
    -- (on the map a click starts a drag, it presses nothing)
    if mapUp() then
        if WaCaNative_CursorPos then
            local x, y = WaCaNative_CursorPos()
            drag = { x = x, y = y, held = {}, moved = os.clock() }
        end
        return
    end
    local t = hovered()
    if not t then
        log("mouse click: no game control under the mouse (%s)", describeMiss())
        return
    end
    -- (the clicked control selected first: the game presses its selected control)
    -- the clicked control becomes the selection, then the game's own CONFIRM KEY presses it - a real key press, exactly
    -- what the keyboard does ("Select Your Cat" ignored a press through the host and the confirm command sent straight to
    -- the screen; Enter worked - VM 2026-10-28); a control outside the navigation (a footer button ...) is pressed through
    -- its host
    local selected, how = selectTarget(t, true)
    if how == "tab" then
        -- (a tab: selecting it turned the page - that was the click)
        log("mouse click: %s (a tab)", t.control:GetFName():ToString())
        return
    end
    local nav = navOf(t)
    local how = "its host"
    local ok, err = pcall(function()
        local cur = nav and nav:IsValid() and nav.CurrentControl
        if selected and cur and cur:IsValid() and sameObject(cur, t.control) then
            local key = keyFor("Button_A")
            WaCa.Command("PressKey|" .. key)
            how = "the confirm key, " .. key
        else
            t.host:OnUIPress(t.control)
            t.host:OnUIRelease(t.control)
        end
    end)
    log("mouse click: %s on %s (%s)%s", t.control:GetFName():ToString(), t.host:GetClass():GetFName():ToString(), how,
        ok and "" or (" (" .. tostring(err) .. ")"))
end

function Menus.Init(c)
    WaCa, log, modDir = c.WaCa, c.log, c.modDir
    local ini = WaCa.ReadIni(modDir .. "/config/keybinds.ini")
    local mouse = ini and ini["Mouse"] or {}
    for row, key in pairs(ini and ini["UIKeys"] or {}) do uiKeys[row] = key end
    enabled = (mouse.MenuCursor or "1") ~= "0"
    gameplayCapture = tonumber(mouse.GameplayCapture or "") or gameplayCapture
    look.yaw = tonumber(mouse.LookYaw or "") or look.yaw
    look.pitch = tonumber(mouse.LookPitch or "") or look.pitch
    -- right / left move the cat sideways relative to the camera (the game's own movement already is camera-relative;
    -- only its camera turn from right / left goes) - 0 = the game's tank-style turning
    WaCa.Command("CameraRelativeMove|" .. ((mouse.CameraRelativeMove or "1") == "0" and "0" or "1"))
    -- no menu cursor handling: nothing tells gameplay from menus, so mouse look is simply on
    if not enabled then Menus.MouseLook(true) return end
    -- Decided on the next tick, never inside the event: a screen is built inside the game's own input handling (the
    -- pause menu inside SwtPlayerController.OnListenCommand), and changing the input mode there (focus, flushed keys)
    -- pulled things from under the game - it crashed opening the pause menu (VM, 2026-10-25). One decision per tick,
    -- however many screens changed.
    local due, dueFull = false, false
    local function later(full)
        if full then dueFull = true end
        if due then return end
        due = true
        ExecuteInGameThread(function()
            local f = dueFull
            due, dueFull = false, false
            update(nil, f)
        end)
    end
    WaCa.On("ScreenShown", function() targetsStale = true later(true) end)
    WaCa.On("ScreenHidden", function() targetsStale = true later(true) end)
    -- hover: the control under the mouse becomes the selected one (native MouseMove, at most every 40 ms)
    WaCa.On("MouseMove", function() ExecuteInGameThread(function() if drag then dragMoved() else hoverMoved() end end) end)
    WaCa.On("ScreenFocusIn", function() later(false) end)
    WaCa.On("ScreenFocusOut", function() later(false) end)
    -- after the game has seen the click (Slate's hover state is current then)
    -- the splash ("press any key") takes keys only: a click there presses Enter (a real key press, native PressKey)
    local splashClass, splash = StaticFindObject("/Script/Wrc.GuiScreenSplash"), nil
    local function isSplash(s)
        local ok, yes = pcall(function() return splashClass and splashClass:IsValid() and s:IsA(splashClass) end)
        return ok and yes
    end
    WaCa.On("ScreenShown", function(s) if isSplash(s) then splash = s:GetFullName() end end)
    WaCa.On("ScreenHidden", function(s) if isSplash(s) then splash = nil end end)
    WaCa.On("KeyUp", function(_, key)
        if key == "LeftMouseButton" then ExecuteInGameThread(stopDrag) end
    end)
    -- the wheel zooms the map: the game zooms while Up / Down are HELD (a tap did nothing - VM 2026-10-28), so each
    -- notch holds the key a moment longer
    local zoom = { key = nil, untilT = 0, gen = 0 }
    local function zoomRelease(gen)
        if zoom.gen ~= gen or not zoom.key then return end
        WaCa.Command("HoldKey|" .. zoom.key .. "|0")
        zoom.key = nil
    end
    WaCa.On("MouseWheel", function(_, notches)
        local n = tonumber(notches) or 0
        if n == 0 or shown ~= true then return end
        ExecuteInGameThread(function()
            if not mapUp() then return end
            local key = n > 0 and "Up" or "Down"
            if zoom.key and zoom.key ~= key then WaCa.Command("HoldKey|" .. zoom.key .. "|0") zoom.key = nil end
            if not zoom.key then
                zoom.key = key
                WaCa.Command("HoldKey|" .. key .. "|1")
            end
            zoom.gen = zoom.gen + 1
            local gen = zoom.gen
            ExecuteInGameThreadWithDelay(math.min(600, 120 * math.abs(n)), function() zoomRelease(gen) end)
        end)
    end)
    WaCa.On("KeyDown", function(_, key)
        if key ~= "LeftMouseButton" then return end
        if splash then
            log("menus: click on the splash - pressing Enter")
            WaCa.Command("PressKey|Enter")
        else
            ExecuteInGameThread(clickHovered)
        end
    end)
end

-- true while a menu is up (the cursor shows): key aliases only apply then
function Menus.InMenu() return shown == true end

return Menus

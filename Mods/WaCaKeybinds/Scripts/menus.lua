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
-- a menu of this mod's own is on top (the controls menu, controls.lua): the mouse leaves the game's menus alone
local heldBy = nil
function Menus.Hold(fn) heldBy = fn end
local function held() return heldBy ~= nil and heldBy() end
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

-- the screens in the order they came (ScreenShown); the newest still up is on top - a popup over the pause menu (its
-- Settings) took the mouse, not the pause menu's tabs under it (VM 2026-10-30: they were hovered through the popup)
local screenOrder = {}             -- menu screens only (not the HUD or an overlay - WaCa.IsGameplayScreen)
local function topScreen()
    for i = #screenOrder, 1, -1 do
        local s = StaticFindObject(screenOrder[i])
        local ok, up = pcall(function() return s and s:IsValid() and s:IsInViewport() end)
        if ok and up then return s end
    end
end

local function onScreen(widget)
    local ok, up = pcall(function()
        local screen = screenOf(widget)
        if not (screen and screen:IsInViewport()) then return false end
        -- (a menu under the top one isn't for the mouse; the HUD and overlays aren't in the order)
        local top = topScreen()
        return not top or top:GetAddress() == screen:GetAddress()
    end)
    return ok and up
end

-- really on screen: the widget and every panel up to its screen visible (a hidden tab's controls keep IsVisible and
-- the place they were last drawn - VM 2026-10-28: the creator's first tab answered for the pattern grid)
-- The pause menu's pages that aren't the current one stay "visible" too (on the Party page the General page's list
-- played its hover sounds, operator 2026-10-30): a pause page counts only while it is its screen's CurrentPanel, and
-- a widget faded out (render opacity 0) not at all.
local widgetClass, pausePanelClass
local function hiddenPage(w)
    pausePanelClass = pausePanelClass or StaticFindObject("/Script/SwtEngine.GuiPausePanel")
    if not (pausePanelClass and w:IsA(pausePanelClass)) then return false end
    local ok, hidden = pcall(function()
        local pause = w.ParentPause
        local cur = pause and pause:IsValid() and pause.CurrentPanel
        return cur and cur:IsValid() and cur:GetAddress() ~= w:GetAddress()
    end)
    return ok and hidden or false
end

local function reallyShown(widget)
    widgetClass = widgetClass or StaticFindObject("/Script/UMG.Widget")
    local w = widget
    for _ = 1, 40 do
        -- (up to the first object that isn't a widget: the top - a tree's outer can be the game instance)
        if not (w and w:IsValid() and widgetClass and w:IsA(widgetClass)) then return true end
        if not w:IsVisible() then return false end
        local okO, opacity = pcall(function() return w:GetRenderOpacity() end)
        if okO and type(opacity) == "number" and opacity < 0.01 then return false end
        if hiddenPage(w) then return false end
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
    targetsAt, targetsStale = WaCa.Now(), false
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

local navOf

-- the selected control keeps the mouse while the mouse is still on it: the main menu grows its selected button over
-- its neighbour, so the mouse on the overlap picked the other one, which grew back over it - Prophecy / Defender Mode
-- flicked back and forth (operator 2026-10-30)
local function keepSelected(t)
    local nav = navOf(t)
    local cur = nav and nav:IsValid() and nav.CurrentControl
    if not (cur and cur:IsValid()) or cur:GetAddress() == t.control:GetAddress() then return t end
    local c = byAddress[cur:GetAddress()]
    if not c then return t end
    local on = cur:IsHovered()
    for _, b in ipairs(c.buttons) do if b:IsValid() and b:IsHovered() then on = true end end
    if on or mouseIn(c) then return c end
    return t
end

local function hovered()
    if targetsStale then listTargets() end
    local t = findHovered()
    if not t and WaCa.Now() - targetsAt > 1 then
        listTargets()
        t = findHovered()
    end
    if t then
        local ok, kept = pcall(keepSelected, t)
        if ok and kept then t = kept end
    end
    return t
end

-- the navigation a control is selected in: a scroll grid's own (the creator's pattern / colour grids keep their
-- selection there, not in their panel's), else its host's
local gridClass
function navOf(t)
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
local BUTTON_TRIGGER_L, BUTTON_TRIGGER_R = 11, 12
local BACK = { [BUTTON_UP] = BUTTON_DOWN, [BUTTON_DOWN] = BUTTON_UP, [BUTTON_LEFT] = BUTTON_RIGHT, [BUTTON_RIGHT] = BUTTON_LEFT }

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
    -- THE LIST'S LAYOUT picks the steps: a ROW (its controls side by side - a tab bar) moves with Right / Left and the
    -- shoulder buttons, on a CLICK only - a tab turns the page, and passing over the bar mustn't; a COLUMN with Down /
    -- Up only. (A Down sent toward a Settings tab went to the page's volume list - Master -> Music - and a Right there
    -- would have turned a volume up: VM 2026-10-30.)
    local row = true
    pcall(function()
        local list, top0 = nav.ControlsNavigation, nil
        for i = 1, #list do
            local _, top = WaCa.WidgetRect(list[i])
            if top then
                top0 = top0 or top
                if math.abs(top - top0) > 12 then row = false end
            end
        end
    end)
    local tries
    if row then
        if not clicked then return false end
        -- (shoulders only: a Right goes to the page below the bar - a Settings volume)
        tries = { to > from and BUTTON_SHOULDER_R or BUTTON_SHOULDER_L }
    else
        tries = to > from and { BUTTON_DOWN } or { BUTTON_UP }
    end
    local pcon = controller()
    local count = #nav.ControlsNavigation
    for _, command in ipairs(tries) do
        local moved = 0
        for _ = 1, count do
            local cur = nav.CurrentControl
            if cur and cur:IsValid() and sameObject(cur, t.control) then
                return true, (command == BUTTON_SHOULDER_L or command == BUTTON_SHOULDER_R) and "tab" or nil
            end
            local before = navIndex(nav, cur)
            screen:OnListenCommand(command, 0, pcon)                  -- (IE_Pressed)
            local after = navIndex(nav, nav.CurrentControl)
            if after == before then break end                         -- (this command doesn't move this list)
            moved = moved + 1
        end
        local cur = nav.CurrentControl
        if cur and cur:IsValid() and sameObject(cur, t.control) then
            return true, (command == BUTTON_SHOULDER_L or command == BUTTON_SHOULDER_R) and "tab" or nil
        end
        -- (these steps didn't get there: step back - a Settings tab isn't in the list, and the steps toward it ran the
        -- list's selection to the bottom, operator 2026-10-30)
        if BACK[command] then
            for _ = 1, moved do screen:OnListenCommand(BACK[command], 0, pcon) end
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
    -- (a hover over a control the steps didn't reach before doesn't step again: each step plays the move sound)
    if not clicked and t.unreached then return false end
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
        t.unreached = true
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

-- THE MAP'S ICONS: what one is, shown next to the mouse (the operator, 2026-10-28: no way to get info on an icon - the
-- game has none to show, not even for its own centre pointer). The name comes from the game: the legend's entry with
-- the same icon (Main Quest, Clan Outpost, Fresh-kill Pile ...), else the creature kind its icon names (a fox head:
-- Fox - the game's ESwtQuestCharacterType names), else the legend entry of its kind (the map's checkpoints: Clan
-- Outposts).
local mapLabel = { map = nil, names = nil, label = nil, shown = nil }
local imageClass

-- every texture an icon shows (the player's icon has a direction arrow too)
local function texturesOf(widget)
    imageClass = imageClass or StaticFindObject("/Script/UMG.Image")
    local found = {}
    local function walk(w, depth)
        if not (w and w:IsValid()) or depth > 6 then return end
        if imageClass and w:IsA(imageClass) then
            pcall(function()
                local res = w.Brush.ResourceObject
                if res and res:IsValid() and reallyShown(w) then found[#found + 1] = res:GetFName():ToString() end
            end)
        end
        local ok, n = pcall(function() return w:GetChildrenCount() end)
        if ok and n then
            for i = 0, n - 1 do walk(w:GetChildAt(i), depth + 1) end
        else
            pcall(function() walk(w.WidgetTree.RootWidget, depth + 1) end)
        end
    end
    walk(widget, 0)
    return found
end

-- an icon image's core name: the legend shows textures (T_UI_Icon_Map_DenVisit_D, T_UI_Icon_Riverclan), the map's
-- icons materials made from them (MI_UI_IconDenVisit, MI_UI_Icon_Riverclan) - both "denvisit" / "riverclan" (the map
-- showed "MI UI IconDenVisit" and nothing for the clan camps, operator 2026-10-30)
local function coreName(name)
    local n = name:gsub("^MI_", ""):gsub("^M_", ""):gsub("^T_", ""):gsub("^UI_", ""):gsub("^Icon_?", ""):gsub("^Map_", "")
        :gsub("_[Dd]$", ""):gsub("_Normal$", "")
    return (n:gsub("[^%w]", ""):lower())
end

-- the legend's names by their icon's core name; the creature kinds
local function mapNames(m)
    local id = m:GetFullName()
    if mapLabel.map == id and mapLabel.names then return mapLabel.names end
    local names = { byTexture = {}, kinds = {}, outpost = nil }
    for _, e in ipairs(FindAllOf("GuiIconWithText") or {}) do
        pcall(function()
            if e:IsValid() and inside(e, m) and e.Icon and e.Icon:IsValid() then
                names.byTexture[coreName(e.Icon:GetFName():ToString())] = e.Text:ToString()
            end
        end)
    end
    pcall(function() names.outpost = m.mcGuiMapLegend.mcGuiLegendOutspot.Text:ToString() end)
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ESwtQuestCharacterType"):ForEachName(function(n)
            local kind = (n:ToString():gsub("^.*::", ""):gsub("^Weak", ""))
            if #kind > 2 then names.kinds[#names.kinds + 1] = kind end
        end)
    end)
    mapLabel.map, mapLabel.names = id, names
    return names
end

-- (the game's text ids for the map's cat icons - MI_UI_IconBarter ...)
local POI_TITLES = { barter = "STR_TITTLE_BARTER", trainer = "STR_MOVES_TRAINER_TITLE", movetrainer = "STR_MOVES_TRAINER_TITLE",
    freshkill = "STR_TITTLE_FRESHKILL" }

local checkpointClass
local function iconName(m, icon)
    -- (another mod's mark - WaCa Clan Life's meeting place ...: its label from the sticky topic "map.marks")
    local markId = icon:GetFName():ToString():match("^WaCaMapMark_(.+)$")
    if markId then
        local labels = WaCa.Latest("map.marks")
        return type(labels) == "table" and labels[markId] or nil
    end
    local names = mapNames(m)
    local texs = {}
    -- (the shared base circle under herbs and creatures - the legend calls it "Enemy" - names nothing: VM 2026-10-28)
    for _, t in ipairs(texturesOf(icon)) do
        if not t:find("_Base", 1, true) then texs[#texs + 1] = t end
    end
    for _, t in ipairs(texs) do
        local name = names.byTexture[coreName(t)]
        if name and name ~= "" then return name end
    end
    -- (one name inside the other: MI_UI_IconTrainer / T_UI_Icon_Map_MoveTrainer_D)
    for _, t in ipairs(texs) do
        local core = coreName(t)
        for k, name in pairs(names.byTexture) do
            if #core >= 4 and #k >= 4 and name ~= "" and (k:find(core, 1, true) or core:find(k, 1, true)) then return name end
        end
    end
    checkpointClass = checkpointClass or StaticFindObject("/Script/Wrc.GuiItemCheckPointMap")
    if checkpointClass and icon:IsA(checkpointClass) and names.outpost then return names.outpost end
    for _, t in ipairs(texs) do
        local lower = t:lower()
        for _, kind in ipairs(names.kinds) do
            if lower:find(kind:lower(), 1, true) then return kind end
        end
    end
    -- the cats the map marks that the legend leaves out: the game's own title for them
    for _, t in ipairs(texs) do
        local id = POI_TITLES[coreName(t)]
        local text = id and WaCa.GetText(id)
        if text and text ~= "" and text ~= id then return text end
    end
    -- (the game's quest-hint pulse - a mod's marker in the world (WaCa Clan Life's duty points) draws one: its name is
    -- that mod's mark at the same place, not the image's "Pulse1" - operator 2026-11-04)
    local front = texs[#texs]
    if front and front:find("Pulse") then
        local labels = WaCa.Latest("map.marks")
        local l, t, r, b = WaCa.WidgetRect(icon)
        local best, bd
        pcall(function()
            local c = m.CanvasGenericIcons
            for i = 0, c:GetChildrenCount() - 1 do
                local w = c:GetChildAt(i)
                local id = w:GetFName():ToString():match("^WaCaMapMark_(.+)$")
                if id and type(labels) == "table" and labels[id] and l then
                    local ml, mt, mr, mb = WaCa.WidgetRect(w)
                    if ml then
                        local d = math.abs((ml + mr) / 2 - l) + math.abs((mt + mb) / 2 - t)
                        if d <= 60 and (not bd or d < bd) then best, bd = labels[id], d end
                    end
                end
            end
        end)
        if best then return best end
    end
    -- else the foreground image's own name, readable (T_UI_Icon_Map_Herb_D: Herb, MI_UI_IconDenVisit: Den Visit)
    if front then
        local readable = front:gsub("^MI_", ""):gsub("^M_", ""):gsub("^T_", ""):gsub("^UI_", ""):gsub("^Icon_?", "")
            :gsub("^Map_", ""):gsub("_[Dd]$", ""):gsub("_Normal$", ""):gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
        if readable ~= "" then return readable end
    end
    if #texs == 0 then
        local what = icon:GetClass():GetFName():ToString()
        if what ~= mapLabel.unnamed then log("map: an icon with no image to name it (%s)", what) end
        mapLabel.unnamed = what
    end
    return nil
end

local function label(m)
    if mapLabel.label then
        local l = StaticFindObject(mapLabel.label)
        if l and l:IsValid() then return l end
    end
    local root = m.WidgetTree.RootWidget
    local l = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), m.WidgetTree, FName("WaCaMapLabel"))
    local slot = root:AddChildToCanvas(l)
    slot:SetAutoSize(true)
    slot:SetZOrder(100)
    -- (the font of a legend entry's text: the legend's TITLE font has a heavy outline that drew as a dark copy off to
    -- the left of a small label - operator 2026-10-30, "drop shadow too far left")
    pcall(function() l:SetFont(m.mcGuiMapLegend.mcGuiLegendOutspot.mcGuiText.Font) end)
    -- (and without its outline: that entry font's OutlineSize is 40 - the "drop shadow way too far left" the operator
    -- saw again 2026-11-04 was that outline, a dark copy of the word drawn ~10 px to its left; VM: 0 = clean)
    pcall(function() local f = l.Font; f.OutlineSettings.OutlineSize = 0; l:SetFont(f) end)
    pcall(function() l:SetShadowOffset({ X = 2, Y = 2 }) l:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
    mapLabel.label = (l:GetFullName():gsub("^%S+ ", ""))
    return l
end

-- WHERE THE MAP IS POINTED AT: the mouse - or, the mouse still for a while (the gamepad moving the map), the screen's
-- middle, where the game's own gamepad cursor sits (operator 2026-11-04: the names showed for the mouse only)
local lastMouse = -math.huge
local function mapPointer(m)
    if os.clock() - lastMouse <= 1.5 then return WaCaNative_CursorPos() end
    local l, t, r, b = WaCa.WidgetRect(m.WidgetTree.RootWidget)
    if l then return (l + r) / 2, (t + b) / 2 end
    return WaCaNative_CursorPos()
end

local function mapHover(m)
    if not WaCaNative_CursorPos then return end
    -- (a map icon is placed by its middle: its widget's box starts where the icon's middle is drawn - VM 2026-10-28,
    -- the cursor on the player's icon was the box's top left corner. The hit area: a square around that point.)
    -- (the MOUSE first, the screen's middle only when the mouse is still AND on no mark: a mouse resting on a mark
    -- flipped its name to 'Player' every 1.5 s - the middle's - QA run on the VM 2026-11-05)
    local cx, cy = WaCaNative_CursorPos()
    local best, bestDist
    local function consider(w)
        if not (w and w:IsValid() and reallyShown(w)) then return end
        local l, t, r, b = WaCa.WidgetRect(w)
        if not l then return end
        local half = math.max(12, math.max(r - l, b - t) / 2)
        local px, py = l, t
        -- (another mod's mark is centred on its point, not placed by its corner like the game's)
        if w:GetFName():ToString():find("^WaCaMapMark_") then px, py = (l + r) / 2, (t + b) / 2 end
        local dx, dy = math.abs(cx - px), math.abs(cy - py)
        if dx <= half and dy <= half and (not bestDist or dx + dy < bestDist) then best, bestDist = w, dx + dy end
    end
    local function search()
        local okc, errc = pcall(function()
            local c = m.CanvasGenericIcons
            for i = 0, c:GetChildrenCount() - 1 do consider(c:GetChildAt(i)) end
            consider(m.mcGuiPlayerIcon)
        end)
        if not okc then log("map: %s", tostring(errc)) end
    end
    search()
    if not best then
        local px, py = mapPointer(m)
        if px ~= cx or py ~= cy then
            cx, cy = px, py
            search()
        end
    end
    local text = best and iconName(m, best) or nil
    local ok, err = pcall(function()
        local l = label(m)
        if not text then
            l:SetVisibility(1)                                  -- (collapsed)
            mapLabel.shown = nil
            return
        end
        local x, y = cx, cy
        local left, top = WaCa.WidgetRect(m.WidgetTree.RootWidget)
        local scale = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(controller())
        l.Slot:SetPosition({ X = (x - (left or 0)) / scale + 40, Y = (y - (top or 0)) / scale + 10 })
        if mapLabel.shown ~= text then
            l:SetText(FText(text))
            mapLabel.shown = text
            log("map: %s", text)
        end
        l:SetVisibility(4)                                      -- (hit-test invisible)
    end)
    if not ok then log("map label: %s", tostring(err)) end
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
    drag.moved = WaCa.Now()
    -- (the mouse held still: the keys go)
    ExecuteInGameThreadWithDelay(150, function()
        if drag and WaCa.Now() - drag.moved >= 0.14 then
            for key in pairs(drag.held) do holdPan(key, false) end
        end
    end)
end

-- THE GAME'S SCROLL LISTS (GuiScrollGrid: Bonds, inventory, quests, help ...): their scroll bar is a slider the game sets
-- from the selection, it moves nothing itself (Pause > Bonds: the bar couldn't be dragged, operator 2026-10-30). So a
-- drag on the bar selects the row that far down the list - the game's own Up / Down - and the wheel steps it: the list
-- scrolls the game's way.
local scrollGridClass
local sliderDrag                   -- { grid, slider, downRaises } while the left button holds a list's bar

local function scrollGridAt(x, y, onBar)
    scrollGridClass = scrollGridClass or StaticFindObject("/Script/SwtEngine.GuiScrollGrid")
    if not scrollGridClass then return nil end
    for _, g in ipairs(FindAllOf("GuiScrollGrid") or {}) do
        local ok, hit, bar = pcall(function()
            if not (g:IsValid() and reallyShown(g)) then return nil end
            local slider = g.mcGuiSliderVertical
            if not (slider and slider:IsValid() and reallyShown(slider)) then return nil end
            local l, t, r, b = WaCa.WidgetRect(onBar and slider or g)
            if not l then return nil end
            -- (the bar is thin: a few pixels either side count)
            local pad = onBar and 12 or 0
            if x >= l - pad and x < r + pad and y >= t and y < b then return g, slider end
        end)
        if ok and hit then return hit, bar end
    end
    return nil
end

-- one Up / Down on the list's screen
local function press(grid, command)
    local screen = screenOf(grid)
    if screen then screen:OnListenCommand(command, 0, controller()) end
end

-- the selected row's control (the grid's own navigation - it changes the moment a step is taken; the bar's value
-- glides there over a few frames, so it can't tell a step from Lua - VM 2026-10-30)
local function selectedRow(grid)
    local ok, c = pcall(function() return grid.GridNavigation.CurrentControl end)
    return ok and c and c:IsValid() and c:GetAddress() or nil
end

-- steps one way until the selection stops moving (the list's end); how many it took
local function toEnd(grid, command)
    local n = 0
    for _ = 1, 500 do
        local before = selectedRow(grid)
        press(grid, command)
        if selectedRow(grid) == before then break end
        n = n + 1
    end
    return n
end

local function sliderMoved()
    if not (sliderDrag and WaCaNative_CursorPos) then return end
    local d = sliderDrag
    if not (d.grid:IsValid() and d.slider:IsValid()) then sliderDrag = nil return end
    local _, y = WaCaNative_CursorPos()
    local _, top, _, bottom = WaCa.WidgetRect(d.slider)
    if not top or bottom <= top then return end
    local f = math.max(0, math.min(1, (y - top) / (bottom - top)))
    -- (the list's length, once per drag: to its top, then counting the steps to its end)
    if not d.rows then
        toEnd(d.grid, BUTTON_UP)
        d.rows = toEnd(d.grid, BUTTON_DOWN) + 1
        d.at = d.rows - 1
        log("mouse: dragging the %s's scroll bar (%d rows)", d.grid:GetClass():GetFName():ToString(), d.rows)
    end
    local want = math.floor(f * (d.rows - 1) + 0.5)
    local command = want > d.at and BUTTON_DOWN or BUTTON_UP
    for _ = 1, math.abs(want - d.at) do press(d.grid, command) end
    d.at = want
end

-- a press on a list's bar starts a drag (true: the click is taken)
local function grabSlider()
    if not WaCaNative_CursorPos then return false end
    local x, y = WaCaNative_CursorPos()
    local grid, slider = scrollGridAt(x, y, true)
    if not grid then return false end
    sliderDrag = { grid = grid, slider = slider }
    sliderMoved()
    return true
end

-- A TAB INSIDE A PAGE (the pause menu's Quest page: Main / Side quests - keys 3 / 4): its page turns with the trigger
-- commands (TriggerL / R), not the screen's own tab bar's shoulders - a click on "Side quests" turned the MAIN bar
-- (operator 2026-10-30). Such a tab: a button state control inside a panel (GuiPanel) below its screen, among sibling
-- tab buttons; the active one shows its CanvasSelected (the game's own state). The trigger is pressed as many times as
-- the clicked tab is from the active one, left / right by where they sit. true = handled.
local buttonStateClass
local function subTabClick(t)
    panelClass = panelClass or StaticFindObject("/Script/SwtEngine.GuiPanel")
    buttonStateClass = buttonStateClass or StaticFindObject("/Script/SwtEngine.GuiButtonState")
    local c = t.control
    if not (panelClass and buttonStateClass and c:IsA(buttonStateClass)) then return false end
    -- (in a panel below the screen? the screen's own tabs aren't)
    local inPanel = false
    local o = c:GetOuter()
    for _ = 1, 24 do
        if not o or not o:IsValid() or (screenClass and o:IsA(screenClass)) then break end
        if o:IsA(panelClass) then inPanel = true break end
        o = o:GetOuter()
    end
    if not inPanel then return false end
    local parent = c:GetParent()
    if not (parent and parent:IsValid()) then return false end
    local tabs = {}
    for i = 0, parent:GetChildrenCount() - 1 do
        local w = parent:GetChildAt(i)
        if w and w:IsValid() and w:IsA(buttonStateClass) and reallyShown(w) then
            local l = WaCa.WidgetRect(w)
            if l then tabs[#tabs + 1] = { w = w, l = l } end
        end
    end
    if #tabs < 2 then return false end
    table.sort(tabs, function(a, b) return a.l < b.l end)
    local function selected(w)
        local ok, yes = pcall(function() return w.CanvasSelected:IsVisible() end)
        return ok and yes
    end
    local from, to
    for i, e in ipairs(tabs) do
        if selected(e.w) then from = i end
        if e.w:GetAddress() == c:GetAddress() then to = i end
    end
    if not (from and to) then return false end
    if from == to then return true end
    local screen = screenOf(c) or t.host
    local command = to > from and BUTTON_TRIGGER_R or BUTTON_TRIGGER_L
    for _ = 1, math.abs(to - from) do screen:OnListenCommand(command, 0, controller()) end
    log("mouse click: %s (a tab in its page - %d step(s) %s)%s", c:GetFName():ToString(), math.abs(to - from),
        to > from and "right" or "left", selected(c) and "" or " - not selected after the steps")
    return true
end

local function clickHovered()
    if shown ~= true then return end
    if grabSlider() then return end
    if clickFooter() or clickCategoryTabs() or clickActionIcon() then return end
    -- (on the map a click starts a drag, it presses nothing)
    if mapUp() then
        if WaCaNative_CursorPos then
            local x, y = WaCaNative_CursorPos()
            drag = { x = x, y = y, held = {}, moved = WaCa.Now() }
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
    if subTabClick(t) then return end
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
    -- THE GAME'S OWN MOUSE (its patch 1.1, 2026-11-02: mouse in menus, left click to choose / interact, its own mouse
    -- look with sensitivity sliders): ours on top doubled every click - buttons needed a double click, the tab bar
    -- marked two tabs, hover fought the game's (operator 2026-11-04). Read from the game itself: its default input
    -- has the mouse-camera axes (Player_Mouse_Camera_Right / _Up) only once it handles the mouse. Then our menu mouse
    -- and mouse look stay off ([Mouse] WhenTheGameHasMouse = Ours keeps them); the rebinding screen and the rest stay.
    local function gameHasMouse()
        local found = false
        pcall(function()
            StaticFindObject("/Script/Engine.Default__InputSettings").AxisMappings:ForEach(function(_, e)
                local name = e:get().AxisName:ToString()
                if name == "Player_Mouse_Camera_Right" or name == "Player_Mouse_Camera_Up" then found = true end
            end)
        end)
        return found
    end
    if gameHasMouse() and (mouse.WhenTheGameHasMouse or "Game") ~= "Ours" then
        log("mouse: the game handles the mouse itself (its input has Player_Mouse_Camera axes) - WaCa's menu mouse " ..
            "and mouse look stay off ([Mouse] WhenTheGameHasMouse = Ours turns them on)")
        return
    end
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
    WaCa.On("ScreenShown", function(screen)
        pcall(function()
            if WaCa.IsGameplayScreen and WaCa.IsGameplayScreen(screen) then return end
            table.insert(screenOrder, (screen:GetFullName():gsub("^%S+ ", "")))
        end)
        targetsStale = true later(true)
    end)
    WaCa.On("ScreenHidden", function(screen)
        pcall(function()
            local path = screen:GetFullName():gsub("^%S+ ", "")
            for i = #screenOrder, 1, -1 do if screenOrder[i] == path then table.remove(screenOrder, i) end end
        end)
        targetsStale = true later(true)
    end)
    -- hover: the control under the mouse becomes the selected one (native MouseMove, at most every 40 ms)
    -- (the map's names follow the map too, not only the mouse: panning it moved the icon away under a still mouse and
    -- the name stayed - operator 2026-11-04; and the gamepad moves the map with no mouse move at all)
    local mapLoop = false
    WaCa.On("ScreenShown", function(screen)
        if mapLoop or not screen:GetClass():GetFName():ToString():find("WorldMap") then return end
        mapLoop = true
        local function tick()
            local m = mapUp()
            if not m then mapLoop = false return end
            if shown == true and not drag and not held() then pcall(mapHover, m) end
            ExecuteInGameThreadWithDelay(150, tick)
        end
        ExecuteInGameThreadWithDelay(150, tick)
    end)
    WaCa.On("MouseMove", function()
        lastMouse = os.clock()
        ExecuteInGameThread(function()
            if held() then return end
            if drag then return dragMoved() end
            if sliderDrag then return sliderMoved() end
            local m = shown == true and mapUp()
            if m then mapHover(m) else hoverMoved() end
        end)
    end)
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
        if key == "LeftMouseButton" then ExecuteInGameThread(function() sliderDrag = nil stopDrag() end) end
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
        if n == 0 or shown ~= true or held() then return end
        ExecuteInGameThread(function()
            if not mapUp() then
                -- over a scroll list: a notch = a step of its selection (wheel up = up)
                if not WaCaNative_CursorPos then return end
                local grid, slider = scrollGridAt(WaCaNative_CursorPos())
                if not grid then return end
                for _ = 1, math.min(10, math.abs(n)) do press(grid, n > 0 and BUTTON_UP or BUTTON_DOWN) end
                return
            end
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
        if key ~= "LeftMouseButton" or held() then return end
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

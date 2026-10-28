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
    for _ = 1, 12 do
        if not o or not o:IsValid() then return nil end
        if (panelClass and o:IsA(panelClass)) or (screenClass and o:IsA(screenClass)) then return o end
        o = o:GetOuter()
    end
    return nil
end

local function clickHovered()
    if shown ~= true then return end
    for _, b in ipairs(FindAllOf("Button") or {}) do
        if b:IsValid() and b:GetFName():ToString() == "mcGuiButtonCollision" and b:IsHovered() then
            local tree = b:GetOuter()
            local control = tree and tree:IsValid() and tree:GetOuter()
            local host = control and control:IsValid() and hostOf(control)
            if host then
                local ok, err = pcall(function()
                    host:OnUIPress(control)
                    host:OnUIRelease(control)
                end)
                log("mouse click: %s on %s%s", control:GetFName():ToString(), host:GetClass():GetFName():ToString(),
                    ok and "" or (" (" .. tostring(err) .. ")"))
                return
            end
        end
    end
end

function Menus.Init(c)
    WaCa, log, modDir = c.WaCa, c.log, c.modDir
    local ini = WaCa.ReadIni(modDir .. "/config/keybinds.ini")
    local mouse = ini and ini["Mouse"] or {}
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
    WaCa.On("ScreenShown", function() later(true) end)
    WaCa.On("ScreenHidden", function() later(true) end)
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

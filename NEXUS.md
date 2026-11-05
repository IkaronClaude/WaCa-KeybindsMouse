# Nexus Mods page - WaCa Keybinds & Mouse

<!-- Paste-ready text for the Nexus Mods upload form. Replace the TODO links once the pages exist. -->

**Name:** WaCa Keybinds & Mouse
**Version:** 1.1.0
**Category:** Controls / User Interface
**Summary (short description, max 350 characters):**
Play with a real mouse and keyboard: a cursor in every menu, click the menus' buttons, mouse look without holding a
button, click to advance dialogue, Escape to go back - and rebind every key. Gamepad untouched.

---

## Description

The game is built like a console game: the mouse cursor is hidden everywhere, clicking a menu does nothing, and the
camera only turns while you hold a mouse button. **WaCa Keybinds & Mouse makes it play like a PC game.**

### 🖱️ The mouse - finally
- **Hover to select, click to press** - the button under the mouse is the selected one. Drag the map, zoom it with the
  wheel, point at a map icon to see what it is.
- **A mouse cursor in every menu** - and **clicking works**: menu buttons, the character creator, the map, the pause
  menu, the splash screen.
- **Mouse look** - the camera follows your mouse directly, like any PC game: no button to hold, no dead zone, no
  acceleration curve, no speed cap. Sensitivity in the settings file; the game's own "invert" options still apply.
- **Left click to interact** (E still works) and **to advance dialogue** - clicking an answer just picks it.
- **Camera-relative movement** - A / D move your cat sideways relative to the camera instead of spinning it ("tank"
  controls). Prefer the game's? One setting.

### ⌨️ Every key, your way
- **Rebind any keyboard or mouse key** for every gameplay command - a real rebinding of the game's own bindings, not
  extra keys on top. Every command and its default is listed in the settings file.
- **Escape pauses** (instead of P) and **goes back / closes every menu**, the character creator included -
  BackSpace still works, and the menus show the Esc icon.
- **Space advances dialogue** like Enter.
- The menus' own keys and key icons, and key aliases for menus and conversations.
- **Your gamepad is never touched.**

Everything lives in one commented file: `Wrc\Binaries\Win64\ue4ss\Mods\WaCaKeybinds\config\keybinds.ini`.

## Requirements
- **UE4SS for Warrior Cats** - https://www.nexusmods.com/warriorcatsclansoftheforest/mods/2
- **WaCa Core** - TODO: Nexus link (the native part that rewrites the game's key bindings)

## Installation
1. Install UE4SS for Warrior Cats and WaCa Core (see their pages).
2. Extract this zip into the game's folder: Steam > right-click the game > Manage > Browse local files. After
   extracting, `Wrc\Binaries\Win64\ue4ss\Mods\WaCaKeybinds` exists.
3. Start the game - it turns itself on. Change keys in `config\keybinds.ini` in that folder.

**Updating from the old all-in-one "WaCa ModKit" (0.7 or older):** remove it first (see WaCa Core's page); its
`config\keybinds.ini` is this mod's file - copy yours over to keep your keys.

**Uninstall:** delete `ue4ss\Mods\WaCaKeybinds` - the game's own controls are back. No game file is changed.

Vortex: untested - install manually.

## Compatibility
- Tested with the Steam version of the game, October 2026 build.
- Works with other mods. Another mod that changes the mouse or the key bindings may conflict - say so in the comments.
- Gamepad play is unaffected.

## Known issues
- Binding changes apply the next time the game rebuilds its bindings (switching between keyboard and gamepad, or
  loading an area); `[Mouse]` settings at the next start.

## Source code & contributing
Open source (Apache 2.0): https://github.com/IkaronClaude/WaCa-KeybindsMouse

**Contributions are very welcome!** Found a menu where the mouse doesn't work, or a key the game still hard-codes?
Open an issue or a pull request on GitHub (or post in the comments) with the menu's name and your
`Wrc\Binaries\Win64\ue4ss\UE4SS.log`.

## AI disclosure
Much of this mod's code and documentation was written with AI assistance (Claude, by Anthropic), directed,
play-tested and released by the author.

## Permissions
Open source under the Apache License 2.0: use it, modify it, include it in modpacks, upload changed versions - keep
the licence and credit, and say what you changed.

## Credits
- UE4SS (RE-UE4SS team), MinHook (Tsuda Kageyu), CaptainJackalope (UE4SS for Warrior Cats on Nexus).

## Changelog
- 1.1.0 - Space confirms in menus; with the game's own mouse controls (its patch 1.1) WaCa's mouse look stays out of
  the way; the map's hover names are readable and follow the gamepad pointer too.
- 1.0.0 - first release as its own mod (from the all-in-one WaCa ModKit 0.7).

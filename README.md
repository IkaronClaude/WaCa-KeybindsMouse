# WaCa Keybinds & Mouse

PC controls for **Warrior Cats: Clans of the Forest**: **a real mouse** and **every key rebindable**.

The game is built like a console game: the mouse cursor is hidden everywhere, clicking a menu button does nothing, and
the camera turns only while you hold a mouse button. This mod makes it play like a PC game.

## The mouse
- **A cursor in every menu**, and **clicking works**: menu buttons, the character creator, the map, the pause menu.
- **Mouse look** in gameplay: the camera follows the mouse directly - no button to hold, no stick dead zone, curve or
  speed cap (`[Mouse] LookYaw` / `LookPitch`; the game's own invert settings apply).
- **Left click** interacts (E still works) and **advances dialogue** - a click on an answer choice just picks it.
- **Camera-relative movement**: A / D move your cat sideways relative to the camera instead of turning it ("tank"
  controls). `[Mouse] CameraRelativeMove = 0` gives the game's back.
- The splash screen ("press any key") takes a click too.

## The keys
- **Rebind any keyboard / mouse key** for every gameplay command (`[Actions]`, `[Axes]`) - a real rebinding of the
  game's own bindings, not keys layered on top. Every command and its default is listed in the file. Gamepad
  bindings are never touched.
- **Escape** pauses (instead of P) and goes back / closes in every menu, the character creator included (BackSpace
  still works); the menus show the Esc icon.
- **Space** advances dialogue like Enter.
- The menus' own keys and their key icons (`[UIKeys]`, `[UIIcons]`), and key aliases in menus (`[KeyAliases]`) and in
  conversations (`[DialogueKeyAliases]`).

All of it in one file: `ue4ss\Mods\WaCaKeybinds\config\keybinds.ini`. Binding changes apply the next time the game
rebuilds its bindings (switching between keyboard and gamepad, or loading an area); `[Mouse]` and the aliases at the
next start.

## Install
Needs **UE4SS for Warrior Cats** ([Nexus](https://www.nexusmods.com/warriorcatsclansoftheforest/mods/2)) and
**[WaCa Core](https://github.com/IkaronClaude/WaCa-Core)** (it reads the key bindings: the game builds them before any
Lua runs). Extract the zip into the game's folder so that `Wrc\Binaries\Win64\ue4ss\Mods\WaCaKeybinds` exists - it
turns itself on (`enabled.txt`). Uninstall: delete that folder; the game's own controls are back.

Coming from the all-in-one WaCa ModKit 0.7? Its `config\keybinds.ini` is this mod's file - copy yours over.

## How it works
- Rebinding: WaCa Core's native half rewrites the game's natively built default bindings before they're installed.
- The cursor: decided whenever a screen comes or goes (WaCa Core's screen events, no polling) - a menu gets
  "game and UI" input with the cursor, gameplay the game's own input with the mouse captured for mouse look.
- Clicks: every menu button has a collision button Slate hit-tests, but the game binds nothing to its click; a left
  click presses the hovered button through its panel's own UI press - the path the game's gamepad uses.
- Key aliases post real key presses to the game window (the menus read raw keys).

## Contributing
Bug reports, ideas and pull requests are very welcome - see [CONTRIBUTING.md](CONTRIBUTING.md). A menu where the mouse
doesn't work? Open an issue with the menu's name and your `UE4SS.log`.

## AI disclosure
Much of this code and documentation was written with AI assistance (Claude, by Anthropic), directed, play-tested and
released by the author.

## License
Apache License 2.0 (see LICENSE).

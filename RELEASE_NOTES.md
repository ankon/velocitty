Velocitty 1.2.1 fixes compositor-configured keyboard remapping on Wayland.

- Special keys now follow the compositor's xkb keymap instead of physical keycodes, fixing options such as Hyprland's `kb_options = caps:swapescape`.
- Key repeat eligibility also follows the keymap, including remapped Caps Lock and Escape.
- Adds a real libxkbcommon regression covering swapped key presses/releases, modified Escape, and repeat.

Windows and macOS downloads are unsigned. Windows may show SmartScreen; macOS users can allow the app in System Settings → Privacy & Security after the first launch attempt.

Use SHA256SUMS to verify the downloaded packages.

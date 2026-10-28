Velocitty 1.2.0 adds native Windows and macOS ports through Peak alongside the existing Linux builds.

- Windows: Win32 window/input/clipboard, ConPTY shells, native fonts, UTF-8 paths, per-monitor DPI, a per-user installer, and a portable ZIP.
- macOS: AppKit window/input/clipboard, POSIX PTYs, Core Text font discovery, Retina rendering, Command+C/V, and a universal Intel/Apple Silicon app in a DMG.
- Linux: Wayland/X11 and Omarchy integration remain supported, with GNU (glibc 2.28+) and dynamically linked musl tarballs for x86_64 and aarch64. The musl builds target systems such as Alpine and require that distribution's musl loader and native GUI libraries.
- Configuration: checked integer parsing, escaped font strings, robust skipping of unrelated TOML settings, and corrected font defaults.
- Branding: the lightning icon is rendered as block ASCII, with an animated README wordmark made using Omarchy's Rust ttfx.

Windows and macOS downloads are unsigned. Windows may show SmartScreen; macOS users can allow the app in System Settings → Privacy & Security after the first launch attempt.

Kitty graphics file/temporary-file transfers and desktop notifications currently use the Linux implementation. Streamed kitty graphics and sixel remain available on all three platforms.

Use SHA256SUMS to verify the downloaded packages.

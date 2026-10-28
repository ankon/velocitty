//! UTF-8 environment access, including native UTF-16 Windows environment values.
const std = @import("std");
const builtin = @import("builtin");

var value_buf: [128 * 1024]u8 = undefined;

/// The Windows slice is valid until the next call; copy it before another lookup.
pub fn get(key: [:0]const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        var name: [256:0]u16 = @splat(0);
        const n = std.unicode.utf8ToUtf16Le(&name, key) catch return null;
        name[n] = 0;
        var wide: [32768]u16 = undefined;
        const len = GetEnvironmentVariableW(&name, &wide, wide.len);
        if (len == 0 or len >= wide.len) return null;
        const bytes = std.unicode.utf16LeToUtf8(&value_buf, wide[0..len]) catch return null;
        return value_buf[0..bytes];
    }
    if (!builtin.link_libc) return null;
    return std.mem.span(std.c.getenv(key) orelse return null);
}

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, value: [*]u16, size: u32) callconv(.winapi) u32;

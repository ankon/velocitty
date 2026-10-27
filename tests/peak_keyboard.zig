const std = @import("std");
const platform = @import("platform");
extern fn test_keyboard_setup(win: *anyopaque, scenario: c_int) void;

test "queued text and modified keys reach the platform wrapper once" {
    for (0..7) |scenario| {
        var win: platform.Window = .{ .impl = .{} };
        test_keyboard_setup(&win.impl.win, @intCast(scenario));
        var ev: platform.Event = undefined;
        if (scenario == 0) {
            try std.testing.expect(win.pollEvent(&ev));
            try std.testing.expectEqualStrings("a", std.mem.sliceTo(&ev.text_input, 0));
            try std.testing.expect(win.pollEvent(&ev));
            try std.testing.expectEqualStrings("b", std.mem.sliceTo(&ev.text_input, 0));
        } else if (scenario >= 5) {
            try std.testing.expect(win.pollEvent(&ev));
            try std.testing.expectEqualStrings("é", std.mem.sliceTo(&ev.text_input, 0));
        } else {
            try std.testing.expect(win.pollEvent(&ev));
            const k = ev.key_press;
            if (scenario == 1) {
                try std.testing.expect(k.mods.alt);
                try std.testing.expectEqual(@as(u21, 'a'), k.cp);
            } else {
                try std.testing.expect(k.mods.ctrl);
                try std.testing.expectEqual(@as(u21, @intCast(scenario + 89)), k.cp);
            }
        }
        try std.testing.expect(!win.pollEvent(&ev));
    }
}

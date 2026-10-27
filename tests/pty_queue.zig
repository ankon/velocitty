const std = @import("std");
const platform = @import("platform");
extern fn queue_test_open() c_int;
extern fn queue_test_read([*]u8, usize) c_int;
extern fn queue_test_close() void;

test "PTY input survives backpressure in order" {
    var pty: platform.Pty = .{ .impl = .{} };
    const fd = queue_test_open();
    try std.testing.expect(fd >= 0);
    defer queue_test_close();
    pty.impl.proc.fd = fd;
    defer pty.close();
    const payload = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i % 251);
    pty.write(payload);
    pty.write("end");
    const output = try std.testing.allocator.alloc(u8, payload.len + 3);
    defer std.testing.allocator.free(output);
    var off: usize = 0;
    var spins: usize = 0;
    while (off < output.len and spins < 100000) : (spins += 1) {
        off += @intCast(queue_test_read(output.ptr + off, output.len - off));
        pty.flush();
    }
    try std.testing.expectEqual(output.len, off);
    try std.testing.expectEqualSlices(u8, payload, output[0..payload.len]);
    try std.testing.expectEqualStrings("end", output[payload.len..]);
}

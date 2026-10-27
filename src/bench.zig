//! Headless benchmarks: PTY → circbuffer scan → VT → render → present copy.
//! Every row reports p50/p95 over individual frames or lookup batches.
//! No window, Peak, or compositor. `zig build bench -- --help`.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const CircBuffer = @import("circbuffer.zig").CircBuffer;
const VtState = @import("vt.zig").VtState;
const Draw = @import("draw.zig");
const Type = @import("type.zig");
const Select = @import("select.zig");

// Same ring, scrollback and glyph cache as main.zig.
const ring_cap = 64 * 1024;
const scrollback = 1000;
const cache_capacity = 2048;
const size_px: f32 = 16;

const font_paths = [_][]const u8{
    "/usr/share/fonts/TTF/IosevkaNerdFontMono-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
};
// main.zig fallback_paths (Linux).
const fallback_paths = [_][]const u8{
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/gnu-free/FreeSans.otf",
    "/usr/share/fonts/noto/NotoColorEmoji.ttf",
};

const Options = struct {
    quick: bool = false,
    mib: u32 = 4,
    burst_kib: u32 = 16,
    cols: u16 = 120,
    rows: u16 = 40,
    samples: u32 = 200,
    font: ?[]const u8 = null,
    only: ?[]const u8 = null,
    help: bool = false,
};

const usage =
    \\Usage: zig build bench -- [options]
    \\  --quick           1 MiB per workload, 40 samples (explicit values still win)
    \\  --mib N           bytes per PTY workload in MiB (1..256; default 4)
    \\  --burst KIB       bytes read per frame (1..48; default 16)
    \\  --grid COLSxROWS  pipeline/render grid (default 120x40)
    \\  --samples N       render frames / glyph batches per row (10..10000; default 200)
    \\  --font PATH       primary font (default: fc-match monospace, like main.zig)
    \\  --only A,B        sections: ascii unicode grapheme csi-short long-escape
    \\                    kitty-image sixel glyph render
    \\  --help
    \\Pipeline rows: one frame = read one burst from a real PTY (writer thread,
    \\raw slave), consumeAndGetRuns, feedRuns, renderSel, damaged-rows copy (present).
    \\io is time inside read(2); time blocked in poll(2) is io-wait, excluded.
    \\Logs: bench/<UTC>-<git12>[-dirty].txt and last_bench.
    \\
;

fn parseOptions(args: []const [*:0]const u8) !Options {
    var opt: Options = .{};
    var seen_mib = false;
    var seen_samples = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[0 .. eq orelse arg.len];
        if (std.mem.eql(u8, name, "--quick") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            if (eq != null) return error.UnexpectedValue;
            if (name[2] == 'q') opt.quick = true else opt.help = true;
            continue;
        }
        const value: []const u8 = if (eq) |at| arg[at + 1 ..] else blk: {
            i += 1;
            if (i == args.len) return error.MissingValue;
            break :blk std.mem.span(args[i]);
        };
        if (value.len == 0 or std.mem.startsWith(u8, value, "--")) return error.MissingValue;
        if (std.mem.eql(u8, name, "--mib")) {
            opt.mib = try count(value, 1, 256);
            seen_mib = true;
        } else if (std.mem.eql(u8, name, "--burst")) {
            opt.burst_kib = try count(value, 1, 48);
        } else if (std.mem.eql(u8, name, "--samples")) {
            opt.samples = try count(value, 10, 10000);
            seen_samples = true;
        } else if (std.mem.eql(u8, name, "--grid")) {
            const x = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidGrid;
            opt.cols = @intCast(count(value[0..x], 2, 1000) catch return error.InvalidGrid);
            opt.rows = @intCast(count(value[x + 1 ..], 2, 1000) catch return error.InvalidGrid);
        } else if (std.mem.eql(u8, name, "--font")) {
            opt.font = value;
        } else if (std.mem.eql(u8, name, "--only")) {
            opt.only = value;
        } else return error.UnknownOption;
    }
    if (opt.quick) {
        if (!seen_mib) opt.mib = 1;
        if (!seen_samples) opt.samples = 40;
    }
    return opt;
}

fn count(value: []const u8, min: u32, max: u32) !u32 {
    for (value) |c| if (c < '0' or c > '9') return error.InvalidCount;
    const n = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCount;
    if (n < min or n > max) return error.InvalidCount;
    return n;
}

fn wanted(opt: Options, section: []const u8) bool {
    const only = opt.only orelse return true;
    var it = std.mem.splitScalar(u8, only, ',');
    while (it.next()) |s| if (std.mem.eql(u8, s, section)) return true;
    return false;
}

const Log = struct {
    buffer: std.Io.Writer.Allocating,
    echo: bool = true,
    fn print(self: *Log, comptime fmt: []const u8, args: anytype) !void {
        if (self.echo) std.debug.print(fmt, args);
        try self.buffer.writer.print(fmt, args);
    }
};

/// Shared setup: fonts and cell metrics.
const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opt: Options,
    ctx: ?*Type.Context,
    cell_w: u32,
    cell_h: u32,
    emoji: bool,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const opt = parseOptions(init.args.vector) catch |err| {
        std.debug.print("bench: invalid arguments: {s}\n{s}", .{ @errorName(err), usage });
        return err;
    };
    if (opt.help) {
        std.debug.print("{s}", .{usage});
        return;
    }
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var log: Log = .{ .buffer = .init(gpa) };
    defer log.buffer.deinit();

    const stamp = try utcStamp(io);
    const git = try gitRev(gpa, io);
    defer gpa.free(git.hash);
    try log.print("velocitty benchmark v3\nutc {s}\ngit {s} status={s}\n", .{ stamp.iso, git.hash, git.status });
    try log.print("compiler Zig {s} optimize={s} target={s}-{s}-{s} cpu-target={s}\n", .{
        builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi), builtin.cpu.model.name,
    });
    try machineInfo(&log, gpa, io);
    try log.print("settings quick={} mib={d} burst={d}KiB grid={d}x{d} samples={d} only={s}\n", .{
        opt.quick, opt.mib, opt.burst_kib, opt.cols, opt.rows, opt.samples, opt.only orelse "all",
    });

    // Fonts: primary + main.zig fallbacks, cache/atlas sized like main.zig.
    var blobs: std.ArrayList(Font) = .empty;
    defer {
        for (blobs.items) |b| {
            gpa.free(b.bytes);
            gpa.free(b.path);
        }
        blobs.deinit(gpa);
    }
    try loadFonts(io, gpa, opt.font, &blobs);
    var ctx_store: Type.Context = try Type.Context.init(gpa, .{ .cache_capacity = cache_capacity });
    defer ctx_store.deinit();
    var env: Env = .{ .gpa = gpa, .io = io, .opt = opt, .ctx = null, .cell_w = 8, .cell_h = 16, .emoji = false };
    if (blobs.items.len != 0) {
        var fallbacks: std.ArrayList(Type.FontId) = .empty;
        defer fallbacks.deinit(gpa);
        for (blobs.items, 0..) |b, i| {
            const id = ctx_store.addFont(b.bytes, .{}) catch {
                try log.print("font {s}: unusable, skipped\n", .{b.path});
                continue;
            };
            if (i != 0) try fallbacks.append(gpa, id);
            if (ctx_store.faces.items[@intFromEnum(id)].font.color != null) env.emoji = true;
            try log.print("font {s} {s} bytes={d}\n", .{ if (i == 0) "primary " else "fallback", b.path, b.bytes.len });
        }
        if (ctx_store.primary != null) {
            try ctx_store.setFallbacks(fallbacks.items);
            const m = try ctx_store.metrics(size_px);
            const h = @ceil(m.ascender - m.descender + m.line_gap);
            const w = @ceil((try ctx_store.glyph('M', size_px)).advance);
            // Bad float-to-int is UB in ReleaseFast.
            if (!std.math.isFinite(w) or !std.math.isFinite(h) or w <= 0 or h <= 0 or w > 256 or h > 256) return error.InvalidFontMetrics;
            env.cell_w = @intFromFloat(w);
            env.cell_h = @intFromFloat(h);
            env.ctx = &ctx_store;
        }
    }
    if (env.ctx == null) try log.print("font NONE: placeholder render, glyph section skipped\n", .{});
    try log.print("size_px={d} cell={d}x{d} glyph-cache={d} atlas=1024x1024 ring={d}\n", .{ size_px, env.cell_w, env.cell_h, cache_capacity, ring_cap });
    try log.print("p50/p95 are nearest-rank over frames (pipeline/render) or 64-lookup batches (glyph).\n", .{});

    spinUp();
    for (workloads) |wl| {
        if (!wanted(opt, wl.name)) continue;
        const bytes = try generate(gpa, wl, @as(usize, opt.mib) << 20);
        defer gpa.free(bytes);
        try runPipeline(&log, &env, wl, bytes);
    }
    if (env.ctx != null and wanted(opt, "glyph")) try glyphSuite(&log, &env);
    if (wanted(opt, "render")) {
        try renderSuite(&log, &env, opt.cols, opt.rows, opt.samples);
        const big_cols: u16 = @intCast(@max(2, 3840 / env.cell_w));
        const big_rows: u16 = @intCast(@max(2, 2160 / env.cell_h));
        try renderSuite(&log, &env, big_cols, big_rows, @max(10, opt.samples / 5));
    }
    try saveLog(io, &log, stamp.file, git.hash, std.mem.eql(u8, git.status, "dirty"));
}

// ---------------------------------------------------------------- statistics

const Pct = struct { p50: f64, p95: f64, mean: f64, sum: f64 };

/// Nearest-rank percentiles. Sorts `values` in place.
fn percentiles(values: []u64) Pct {
    std.debug.assert(values.len != 0);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    var sum: f64 = 0;
    for (values) |v| sum += @floatFromInt(v);
    return .{
        .p50 = @floatFromInt(values[rank(values.len, 50)]),
        .p95 = @floatFromInt(values[rank(values.len, 95)]),
        .mean = sum / @as(f64, @floatFromInt(values.len)),
        .sum = sum,
    };
}

fn rank(n: usize, p: usize) usize {
    return @max(1, (n * p + 99) / 100) - 1;
}

/// Busy 500 ms so frequency scaling ramps before the first section is timed.
fn spinUp() void {
    const end = nowNs() + 500 * std.time.ns_per_ms;
    var x: u64 = 1;
    while (nowNs() < end) {
        for (0..10_000) |_| x = x *% 6364136223846793005 +% 1442695040888963407;
        std.mem.doNotOptimizeAway(x);
    }
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------- workloads

const Workload = struct {
    name: []const u8,
    about: []const u8,
    unit: *const fn (*Gen) anyerror!void,
};

const workloads = [_]Workload{
    .{ .name = "ascii", .about = "printable lines 10..120 cols, CRLF", .unit = genAscii },
    .{ .name = "unicode", .about = "single-codepoint non-ASCII: Latin/Greek/Cyrillic/box/CJK/Hangul/emoji", .unit = genUnicode },
    .{ .name = "grapheme", .about = "multi-codepoint clusters: combining, ZWJ, flags, skin tones, VS16, Indic, jamo", .unit = genGrapheme },
    .{ .name = "csi-short", .about = "TUI redraw: CUP/EL/CUF + short SGR around 1..8 chars", .unit = genCsiShort },
    .{ .name = "long-escape", .about = "truecolor+underline SGR, OSC 8 long URLs, OSC 0/7/133, OSC 52 1-3 KiB", .unit = genLongEscape },
    .{ .name = "kitty-image", .about = "kitty APC a=T f=32 64x64 RGBA, 4096-byte base64 chunks, ids 1..16", .unit = genKitty },
    .{ .name = "sixel", .about = "DCS q 64x64, 8-color palette, RLE bands", .unit = genSixel },
};

const Gen = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    rng: u64 = 0x9E3779B97F4A7C15,
    n: u32 = 0,

    fn next(self: *Gen) u64 {
        // splitmix64: deterministic, no seed option.
        self.rng +%= 0x9E3779B97F4A7C15;
        var z = self.rng;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
    fn below(self: *Gen, n: usize) usize {
        return @intCast(self.next() % n);
    }
    fn pick(self: *Gen, pool: []const []const u8) []const u8 {
        return pool[self.below(pool.len)];
    }
    fn put(self: *Gen, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }
    fn fmt(self: *Gen, comptime f: []const u8, args: anytype) !void {
        try self.out.print(self.gpa, f, args);
    }
    fn word(self: *Gen, len: usize) !void {
        const alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./";
        for (0..len) |_| try self.out.append(self.gpa, alpha[self.below(alpha.len)]);
    }
};

fn generate(gpa: std.mem.Allocator, wl: Workload, target: usize) ![]u8 {
    var g: Gen = .{ .gpa = gpa };
    errdefer g.out.deinit(gpa);
    try g.out.ensureTotalCapacity(gpa, target + 64 * 1024);
    while (g.out.items.len < target) : (g.n += 1) try wl.unit(&g);
    return g.out.toOwnedSlice(gpa);
}

fn genAscii(g: *Gen) !void {
    const chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 (){}[];:,.<>=+-*/\"'#!?";
    const len = 10 + g.below(111);
    for (0..len) |_| try g.out.append(g.gpa, chars[g.below(chars.len)]);
    try g.put("\r\n");
}

const unicode_pool = [_][]const u8{
    "é", "ñ", "ü", "ß", "ø", "Ω", "λ", "π", "Ж", "я", "ש", "─", "│", "┌", "┘", "█", "░", "→", "✓", "★", "€", "©",
    "汉", "字", "測", "試", "日", "本", "語", "한", "글", "あ", "ア", "😀", "🚀", "🎉", "🔥", "✨",
};

fn genUnicode(g: *Gen) !void {
    const len = 10 + g.below(40);
    for (0..len) |_| {
        if (g.below(6) == 0) try g.put(" ") else try g.put(g.pick(&unicode_pool));
    }
    try g.put("\r\n");
}

const grapheme_pool = [_][]const u8{
    "e\u{301}",        "a\u{308}\u{323}", "n\u{303}",       "o\u{302}\u{301}",
    "Z\u{335}\u{336}\u{337}\u{338}\u{334}\u{33F}",
    "👨\u{200D}👩\u{200D}👧\u{200D}👦", "👩🏻\u{200D}💻", "🏳\u{FE0F}\u{200D}🌈",
    "👍🏽",               "🇵🇹",              "🇯🇵",              "❤\u{FE0F}",
    "1\u{FE0F}\u{20E3}", "क्षि",             "\u{1100}\u{1161}\u{11A8}", "ก\u{E34}\u{E48}",
};

fn genGrapheme(g: *Gen) !void {
    const len = 5 + g.below(25);
    for (0..len) |_| {
        try g.put(g.pick(&grapheme_pool));
        if (g.below(3) == 0) try g.put(" ");
    }
    try g.put("\r\n");
}

fn genCsiShort(g: *Gen) !void {
    const sgr = [_][]const u8{ "\x1b[0m", "\x1b[m", "\x1b[1m", "\x1b[7m", "\x1b[31m", "\x1b[32m", "\x1b[1;34m", "\x1b[39m", "\x1b[4m", "\x1b[22m" };
    const moves = [_][]const u8{ "\x1b[K", "\x1b[2C", "\x1b[A", "\x1b[B", "\x1b[3D", "\x1b[?25l", "\x1b[?25h", "\r\n" };
    try g.fmt("\x1b[{d};{d}H", .{ 1 + g.below(60), 1 + g.below(200) });
    const segs = 3 + g.below(10);
    for (0..segs) |_| {
        try g.put(g.pick(&sgr));
        try g.word(1 + g.below(8));
        if (g.below(3) == 0) try g.put(g.pick(&moves));
    }
}

fn genLongEscape(g: *Gen) !void {
    switch (g.below(10)) {
        0...3 => {
            const c = g.next();
            try g.fmt("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d};1;3;4:3;58;2;{d};{d};{d}m", .{
                c & 255, (c >> 8) & 255, (c >> 16) & 255, (c >> 24) & 255, (c >> 32) & 255, (c >> 40) & 255, (c >> 48) & 255, (c >> 56) & 255, c & 127,
            });
            try g.word(5 + g.below(20));
            try g.put("\x1b[0m ");
        },
        4...5 => {
            try g.fmt("\x1b]8;id=l{d};https://example.com/", .{g.n});
            try g.word(150 + g.below(150));
            try g.put("\x1b\\");
            try g.word(8 + g.below(16));
            try g.put("\x1b]8;;\x1b\\ ");
        },
        6 => {
            try g.put("\x1b]0;");
            try g.word(60 + g.below(140));
            try g.put("\x07");
        },
        7 => {
            try g.put("\x1b]133;A\x07\x1b]7;file://host/home/user/");
            try g.word(40 + g.below(80));
            try g.put("\x1b\\\x1b]133;B\x07$ ");
            try g.word(10);
            try g.put("\x1b]133;C\x07\r\n\x1b]133;D;0\x07");
        },
        8 => {
            var raw: [3072]u8 = undefined;
            const n = 1024 + g.below(2048);
            for (raw[0..n]) |*b| b.* = @truncate(g.next());
            var enc: [4096]u8 = undefined;
            try g.put("\x1b]52;c;");
            try g.put(std.base64.standard.Encoder.encode(&enc, raw[0..n]));
            try g.put("\x07");
        },
        else => try g.put("\r\n"),
    }
}

fn genKitty(g: *Gen) !void {
    const side = 64;
    const id = 1 + g.n % 16;
    var rgba: [side * side * 4]u8 = undefined;
    for (0..side) |y| for (0..side) |x| {
        const p = (y * side + x) * 4;
        rgba[p..][0..4].* = .{ @intCast(x * 4), @intCast(y * 4), @truncate(id * 16), 255 };
    };
    var enc: [std.base64.standard.Encoder.calcSize(rgba.len)]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&enc, &rgba);
    var off: usize = 0;
    while (off < b64.len) {
        const end = @min(off + 4096, b64.len);
        const more: u8 = if (end < b64.len) 1 else 0;
        if (off == 0) {
            try g.fmt("\x1b_Ga=T,f=32,s={d},v={d},i={d},q=2,m={d};", .{ side, side, id, more });
        } else try g.fmt("\x1b_Gm={d};", .{more});
        try g.put(b64[off..end]);
        try g.put("\x1b\\");
        off = end;
    }
    try g.put("\r\n");
    for (0..4) |_| try genAscii(g);
}

fn genSixel(g: *Gen) !void {
    const side = 64;
    const seed = g.n % 8;
    try g.fmt("\x1bPq\"1;1;{d};{d}", .{ side, side });
    for (0..8) |c| try g.fmt("#{d};2;{d};{d};{d}", .{ c, (c * 37) % 101, (c * 53) % 101, (c * 71) % 101 });
    var band: usize = 0;
    while (band < side) : (band += 6) {
        for (0..8) |c| {
            try g.fmt("#{d}", .{c});
            var x: usize = 0;
            while (x < side) {
                const bits = sixelBits(band, x, c, seed);
                var run: usize = 1;
                while (x + run < side and sixelBits(band, x + run, c, seed) == bits) run += 1;
                const ch: u8 = '?' + @as(u8, bits);
                if (run > 3) try g.fmt("!{d}{c}", .{ run, ch }) else for (0..run) |_| try g.out.append(g.gpa, ch);
                x += run;
            }
            try g.put(if (c == 7) "-" else "$");
        }
    }
    try g.put("\x1b\\\r\n");
    for (0..4) |_| try genAscii(g);
}

fn sixelBits(band: usize, x: usize, color: usize, seed: usize) u6 {
    var bits: u6 = 0;
    for (0..6) |dy| {
        const y = band + dy;
        if ((x / 8 + y / 8 + seed) % 8 == color) bits |= @as(u6, 1) << @intCast(dy);
    }
    return bits;
}

// ---------------------------------------------------------------- PTY pipeline

const Pty = struct {
    master: linux.fd_t,
    slave: linux.fd_t,

    /// /dev/ptmx + TIOCGPTPEER; slave raw (no ONLCR, no echo) so bytes arrive verbatim.
    fn open() !Pty {
        const m = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(m) != .SUCCESS) return error.PtyOpen;
        const master: linux.fd_t = @intCast(m);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyOpen;
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
        const s = linux.ioctl(master, linux.T.IOCGPTPEER, @as(u32, @bitCast(flags)));
        if (linux.errno(s) != .SUCCESS) return error.PtyOpen;
        const slave: linux.fd_t = @intCast(s);
        errdefer _ = linux.close(slave);
        var t = try posix.tcgetattr(slave);
        t.iflag = .{};
        t.oflag = .{};
        t.lflag = .{};
        t.cflag.CSIZE = .CS8;
        t.cflag.PARENB = false;
        try posix.tcsetattr(slave, .NOW, t);
        return .{ .master = master, .slave = slave };
    }
};

fn writerMain(fd: linux.fd_t, bytes: []const u8, failed: *bool) void {
    var rest = bytes;
    while (rest.len != 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR, .AGAIN => {},
            else => {
                failed.* = true;
                return;
            },
        }
    }
}

const Stage = enum { io, scan, vt, render, present };
const stage_count = std.enums.values(Stage).len;

const Pipeline = struct {
    ring: CircBuffer,
    term: VtState,
    frame: Draw.Frame,
    present: []u32,

    fn init(env: *const Env, cols: u16, rows: u16) !Pipeline {
        var ring = try CircBuffer.create(env.gpa, ring_cap);
        errdefer ring.destroy();
        var term = try VtState.init(env.gpa, cols, rows, scrollback, ring.storage);
        errdefer term.deinit();
        var frame = try Draw.Frame.init(env.gpa, @as(u32, cols) * env.cell_w, @as(u32, rows) * env.cell_h);
        errdefer frame.deinit();
        const present = try env.gpa.alloc(u32, frame.pixels.len);
        @memset(present, 0);
        return .{ .ring = ring, .term = term, .frame = frame, .present = present };
    }

    fn deinit(self: *Pipeline, gpa: std.mem.Allocator) void {
        gpa.free(self.present);
        self.frame.deinit();
        self.term.deinit();
        self.ring.destroy();
    }

    /// main.zig Presenter: copy only the damaged rows to the window buffer.
    fn presentDamage(self: *Pipeline) void {
        if (!self.frame.damaged()) return;
        const y0: usize = if (self.frame.dirty_full) 0 else self.frame.dirty_y;
        const h: usize = if (self.frame.dirty_full) self.frame.height else self.frame.dirty_h;
        const w = self.frame.width;
        @memcpy(self.present[y0 * w ..][0 .. h * w], self.frame.pixels[y0 * w ..][0 .. h * w]);
        std.mem.doNotOptimizeAway(self.present);
    }

    /// What main.zig hands to the window between frames; not timed.
    fn drainHost(self: *Pipeline) void {
        const t = &self.term;
        t.reply.clearRetainingCapacity();
        t.title_dirty = false;
        t.app_id_dirty = false;
        t.pointer_dirty = false;
        t.notify_pending = false;
        t.clip_kind = 0;
        t.clip.clearRetainingCapacity();
    }
};

fn runPipeline(log: *Log, env: *Env, wl: Workload, bytes: []const u8) !void {
    const gpa = env.gpa;
    const opt = env.opt;
    const burst: usize = @as(usize, opt.burst_kib) * 1024;
    const frames = (bytes.len + burst - 1) / burst;
    const warm = @min(16, frames / 10);
    var p = try Pipeline.init(env, opt.cols, opt.rows);
    defer p.deinit(gpa);
    if (env.ctx) |c| c.clearAtlas();
    const misses0 = if (env.ctx) |c| c.stats.misses else 0;

    var stage_ns: [stage_count][]u64 = undefined;
    for (&stage_ns) |*s| s.* = try gpa.alloc(u64, frames);
    defer for (stage_ns) |s| gpa.free(s);
    const total_ns = try gpa.alloc(u64, frames);
    defer gpa.free(total_ns);
    var wait_ns: u64 = 0;
    var reads: u64 = 0;
    var runs: u64 = 0;

    const pty = try Pty.open();
    var write_failed = false;
    const writer = try std.Thread.spawn(.{}, writerMain, .{ pty.slave, bytes, &write_failed });
    // Closing the master first unblocks a writer stuck on a full PTY.
    defer {
        _ = linux.close(pty.master);
        writer.join();
        _ = linux.close(pty.slave);
    }

    const mask = p.ring.capacity - 1;
    var fed: usize = 0;
    for (0..frames) |f| {
        const want = @min(burst, bytes.len - fed);
        if (p.ring.head - p.ring.tail + want > p.ring.capacity) return error.RingOverrun;
        var io_ns: u64 = 0;
        var got: usize = 0;
        while (got < want) {
            const off: usize = @intCast(p.ring.head & mask);
            const t0 = nowNs();
            const rc = linux.read(pty.master, p.ring.storage[off..].ptr, want - got);
            const t1 = nowNs();
            io_ns += t1 - t0;
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.PtyEof;
                    if (!p.ring.mapped) mirror(&p.ring, off, rc);
                    p.ring.head += rc;
                    got += rc;
                    reads += 1;
                },
                .AGAIN => {
                    var pfd = [1]linux.pollfd{.{ .fd = pty.master, .events = linux.POLL.IN, .revents = 0 }};
                    const rc_poll = linux.poll(&pfd, 1, 5000);
                    wait_ns += nowNs() - t1;
                    if (rc_poll == 0 or write_failed) return error.PtyStalled;
                },
                .INTR => {},
                else => return error.PtyRead,
            }
        }
        fed += want;
        const t0 = nowNs();
        const r = p.ring.consumeAndGetRuns(std.math.maxInt(usize));
        runs += r.len;
        const t1 = nowNs();
        if (r.len != 0) p.term.feedRuns(r);
        const t2 = nowNs();
        p.drainHost();
        const t3 = nowNs();
        p.frame.renderSel(&p.term, env.cell_w, env.cell_h, env.ctx, size_px, .{});
        p.term.clearDirty();
        const t4 = nowNs();
        p.presentDamage();
        const t5 = nowNs();
        const ns = [stage_count]u64{ io_ns, t1 - t0, t2 - t1, t4 - t3, t5 - t4 };
        total_ns[f] = 0;
        for (ns, 0..) |v, i| {
            stage_ns[i][f] = v;
            total_ns[f] += v;
        }
    }
    if (p.ring.head != p.ring.tail) return error.PipelineHeldBytes;

    const kept = frames - warm;
    try log.print("\npipeline {s}: {s}\n", .{ wl.name, wl.about });
    try log.print("  bytes={d} frames={d} (+{d} warm discarded) burst={d} B grid={d}x{d} reads/frame={d:.1} runs/frame={d:.0}\n", .{
        bytes.len - @min(bytes.len, warm * burst), kept, warm, burst, opt.cols, opt.rows,
        @as(f64, @floatFromInt(reads)) / @as(f64, @floatFromInt(frames)), @as(f64, @floatFromInt(runs)) / @as(f64, @floatFromInt(frames)),
    });
    try log.print("  {s:<8} {s:>10} {s:>10} {s:>10} {s:>7}\n", .{ "stage", "p50 us", "p95 us", "mean us", "share" });
    const total = percentiles(total_ns[warm..]);
    var share: [stage_count]f64 = undefined;
    for (std.enums.values(Stage), 0..) |stage, i| {
        const s = percentiles(stage_ns[i][warm..]);
        share[i] = s.sum / total.sum * 100;
        try log.print("  {s:<8} {d:>10.1} {d:>10.1} {d:>10.1} {d:>6.1}%\n", .{ @tagName(stage), s.p50 / 1000, s.p95 / 1000, s.mean / 1000, share[i] });
    }
    const kept_bytes: f64 = @floatFromInt(bytes.len - @min(bytes.len, warm * burst));
    try log.print("  {s:<8} {d:>10.1} {d:>10.1} {d:>10.1}  {d:.1} MiB/s\n", .{ "frame", total.p50 / 1000, total.p95 / 1000, total.mean / 1000, kept_bytes / (total.sum / 1e9) / (1024 * 1024) });
    try log.print("  split: io {d:.1}% | parse {d:.1}% (scan {d:.1} + vt {d:.1}) | render {d:.1}% (draw {d:.1} + copy {d:.1})\n", .{
        share[0], share[1] + share[2], share[1], share[2], share[3] + share[4], share[3], share[4],
    });
    const misses = if (env.ctx) |c| c.stats.misses - misses0 else 0;
    try log.print("  io-wait {d:.1} us/frame (excluded) glyph-misses={d} images={d} placements={d} checksum={x}\n", .{
        @as(f64, @floatFromInt(wait_ns)) / @as(f64, @floatFromInt(frames)) / 1000, misses, p.term.kitty.images.items.len, p.term.kitty.placements.items.len,
        hashTerm(&p.term) ^ hashBytes(std.mem.sliceAsBytes(p.frame.pixels)),
    });
}

// Same as CircBuffer.syncMirror for the unmapped fallback.
fn mirror(ring: *CircBuffer, off: usize, n: usize) void {
    const cap = ring.capacity;
    const a = ring.storage;
    const first = @min(n, cap - off);
    @memcpy(a[off + cap ..][0..first], a[off..][0..first]);
    const rest = n - first;
    @memcpy(a[0..rest], a[cap..][0..rest]);
}

// ---------------------------------------------------------------- glyph cache

const batch = 64;

fn glyphSuite(log: *Log, env: *Env) !void {
    const ctx = env.ctx.?;
    const gpa = env.gpa;
    const samples = env.opt.samples;
    try log.print("\nglyph cache: ns/lookup over {d}-lookup batches, {d} batches/row; LRU capacity {d}\n", .{ batch, samples, cache_capacity });

    // Distinct drawable glyphs: Latin-ext/Greek/Cyrillic/box/arrows, then CJK.
    var small: std.ArrayList(u21) = .empty;
    defer small.deinit(gpa);
    var cjk: std.ArrayList(u21) = .empty;
    defer cjk.deinit(gpa);
    try collect(ctx, gpa, &small, &.{ .{ 0x100, 0x250 }, .{ 0x370, 0x400 }, .{ 0x400, 0x500 }, .{ 0x2190, 0x2200 }, .{ 0x2500, 0x2580 } }, 1024);
    try collect(ctx, gpa, &cjk, &.{.{ 0x4E00, 0x9FFF }}, 8192);
    var emoji: std.ArrayList(u21) = .empty;
    defer emoji.deinit(gpa);
    if (env.emoji) try collect(ctx, gpa, &emoji, &.{ .{ 0x1F600, 0x1F650 }, .{ 0x1F680, 0x1F6C6 }, .{ 0x1F300, 0x1F3F0 } }, 256);
    try log.print("  pools: small={d} cjk={d} color-emoji={d} (distinct drawable glyphs)\n", .{ small.items.len, cjk.items.len, emoji.items.len });
    try log.print("  {s:<38} {s:>9} {s:>9} {s:>9} {s:>7} {s:>7}\n", .{ "case", "p50 ns", "p95 ns", "mean ns", "hit%", "resets" });

    var ascii: [95]u21 = undefined;
    for (&ascii, 0..) |*c, i| c.* = @intCast(32 + i);
    try glyphRow(log, env, "glyph() ASCII table", &ascii, .hit_glyph);
    if (small.items.len >= batch) {
        const hot = small.items[0..@min(256, small.items.len)];
        try glyphRow(log, env, "glyph() hit, 256 non-ASCII", hot, .hit_glyph);
        try glyphRow(log, env, "peekGlyph() hit (render path)", hot, .hit_peek);
        try glyphRow(log, env, "miss: raster+pack Latin/Greek/box", small.items, .miss);
    }
    if (cjk.items.len >= 256) {
        // Fallback-font glyphs: resolve() walks cmaps before the cache key exists.
        try glyphRow(log, env, "glyph() hit, 256 CJK (fallback face)", cjk.items[0..256], .hit_glyph);
        try glyphRow(log, env, "peekGlyph() hit, 256 CJK", cjk.items[0..256], .hit_peek);
        try glyphRow(log, env, "miss: raster+pack CJK", cjk.items, .miss);
    }
    if (emoji.items.len >= batch) {
        try glyphRow(log, env, "miss: color emoji (CBDT decode+scale)", emoji.items, .miss);
        try glyphRow(log, env, "glyph() hit, color emoji", emoji.items[0..batch], .hit_glyph);
    }

    // Working-set sweep around the LRU capacity, uniform random access.
    if (cjk.items.len >= 2 * cache_capacity) {
        const sets = [_]u32{ cache_capacity / 2, cache_capacity * 9 / 10, cache_capacity * 11 / 10, cache_capacity * 2 };
        for (sets) |ws| {
            var name_buf: [64]u8 = undefined;
            try glyphRow(log, env, try std.fmt.bufPrint(&name_buf, "uniform working set {d}", .{ws}), cjk.items[0..ws], .uniform);
        }
        try retention(log, env, cjk.items);
    } else try log.print("  working-set sweep SKIPPED: needs {d} CJK glyphs (Noto Sans CJK)\n", .{2 * cache_capacity});
    ctx.clearAtlas();
}

/// Does a hot set survive a stream of new glyphs (scrolling CJK text)?
/// A true LRU keeps all 64 hot glyphs (each is touched every 4 lookups);
/// a cache whose hits do not refresh recency evicts them every `capacity` inserts.
fn retention(log: *Log, env: *Env, pool: []const u21) !void {
    const ctx = env.ctx.?;
    const hot = pool[0..64];
    const cold = pool[64..];
    // 1.25x capacity: enough to cycle the LRU, small enough that the atlas
    // does not fill (a full atlas resets every cache and hides eviction policy).
    const stream = cache_capacity + cache_capacity / 4;
    ctx.clearAtlas();
    for (hot) |cp| _ = try ctx.glyph(cp, size_px);
    var hot_lookups: u64 = 0;
    var hot_misses: u64 = 0;
    var resets: u32 = 0;
    var shelf = ctx.atlas.shelf_y;
    for (0..stream) |i| {
        _ = try ctx.glyph(cold[i % cold.len], size_px);
        if (ctx.atlas.shelf_y < shelf) resets += 1;
        shelf = ctx.atlas.shelf_y;
        if (i % 3 != 2) continue;
        const before = ctx.stats.misses;
        _ = try ctx.glyph(hot[hot_lookups % hot.len], size_px);
        hot_misses += ctx.stats.misses - before;
        hot_lookups += 1;
    }
    try log.print("  hot-64 retention, {d} new glyphs, 3 new : 1 hot -> hot hit {d:.1}% ({d} hot misses, {d} atlas resets; LRU ideal 100%)\n", .{
        stream, 100 * (1 - @as(f64, @floatFromInt(hot_misses)) / @as(f64, @floatFromInt(hot_lookups))), hot_misses, resets,
    });
}

fn collect(ctx: *Type.Context, gpa: std.mem.Allocator, out: *std.ArrayList(u21), ranges: []const [2]u21, max: usize) !void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    ctx.clearAtlas();
    for (ranges) |r| {
        var cp = r[0];
        while (cp < r[1] and out.items.len < max) : (cp += 1) {
            const g = ctx.glyph(cp, size_px) catch continue;
            if (g.glyph_id == 0 or g.width == 0) continue;
            const key = (@as(u64, @intFromEnum(g.font_id)) << 32) | g.glyph_id;
            if ((try seen.getOrPut(gpa, key)).found_existing) continue;
            try out.append(gpa, cp);
        }
    }
    ctx.clearAtlas();
}

const GlyphCase = enum { hit_glyph, hit_peek, miss, uniform };

fn glyphRow(log: *Log, env: *Env, name: []const u8, pool: []const u21, case: GlyphCase) !void {
    const ctx = env.ctx.?;
    const samples = env.opt.samples;
    const ns = try env.gpa.alloc(u64, samples);
    defer env.gpa.free(ns);
    var rng: Gen = .{ .gpa = env.gpa };
    var cursor: usize = 0;
    var lookups: u64 = 0;
    var misses: u64 = 0;
    var resets: u32 = 0;
    var acc: u64 = 0;
    ctx.clearAtlas();
    // Prefill so hits measure a warm cache; sweeps start from a full working set.
    if (case != .miss) for (pool) |cp| {
        _ = try ctx.glyph(cp, size_px);
    };
    var codes: [batch]u21 = undefined;
    var warm: u32 = 3;
    var s: u32 = 0;
    while (s < samples) {
        for (&codes, 0..) |*c, i| c.* = switch (case) {
            .hit_glyph, .hit_peek, .miss => pool[(cursor + i) % pool.len],
            .uniform => pool[rng.below(pool.len)],
        };
        if (case == .miss) {
            // Fresh atlas per batch; ASCII re-warm is outside the timer.
            ctx.clearAtlas();
            cursor = (cursor + batch) % pool.len;
        } else if (case != .uniform) cursor = (cursor + batch) % pool.len;
        const before = ctx.stats.misses;
        const shelf = ctx.atlas.shelf_y;
        const t0 = nowNs();
        for (codes) |cp| {
            const g = if (case == .hit_peek) ctx.peekGlyph(cp, size_px) orelse return error.CacheNotWarm else try ctx.glyph(cp, size_px);
            acc +%= g.glyph_id;
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(acc);
        if (ctx.atlas.shelf_y < shelf) resets += 1;
        if (warm > 0) {
            warm -= 1;
            continue;
        }
        ns[s] = t1 - t0;
        lookups += batch;
        misses += ctx.stats.misses - before;
        s += 1;
    }
    const p = percentiles(ns);
    const hit = 100 * (1 - @as(f64, @floatFromInt(misses)) / @as(f64, @floatFromInt(lookups)));
    try log.print("  {s:<38} {d:>9.1} {d:>9.1} {d:>9.1} {d:>6.1}% {d:>7}\n", .{ name, p.p50 / batch, p.p95 / batch, p.mean / batch, hit, resets });
}

// ---------------------------------------------------------------- render

const RenderCase = enum { full, skip, single, line, cursor, selection, scroll, resize };

fn renderSuite(log: *Log, env: *Env, cols: u16, rows: u16, samples: u32) !void {
    var p = try Pipeline.init(env, cols, rows);
    defer p.deinit(env.gpa);
    try log.print("\nrender {d}x{d} ({d}x{d} px), {d} frames/row; mutation untimed except resize\n", .{ cols, rows, p.frame.width, p.frame.height, samples });
    try log.print("  {s:<24} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "case", "p50 us", "p95 us", "mean us", "rows/frame" });
    const ns = try env.gpa.alloc(u64, samples);
    defer env.gpa.free(ns);
    for (std.enums.values(RenderCase)) |case| {
        try p.term.resize(cols, rows);
        try p.frame.resize(@as(u32, cols) * env.cell_w, @as(u32, rows) * env.cell_h);
        fillScreen(&p.term);
        p.term.flags.cursor_visible = case == .cursor;
        p.frame.invalidate();
        p.frame.render(&p.term, env.cell_w, env.cell_h, env.ctx, size_px);
        p.term.clearDirty();
        var sel: Select.State = .{};
        var damage: u64 = 0;
        for (0..samples + 2) |i| {
            const cp: u21 = if (i % 2 == 0) '#' else '@';
            const row = rows / 2;
            switch (case) {
                .full => {
                    p.frame.invalidate();
                    p.term.markDirtyAll();
                },
                .skip => {},
                .single, .line => {
                    p.term.grid().cursor = .{ .row = row, .col = 0 };
                    p.term.grid().wrap_pending = false;
                    const n: u16 = if (case == .single) 1 else cols;
                    for (0..n) |_| p.term.printCodepoint(cp);
                },
                .cursor => {
                    p.term.grid().cursor = .{ .row = row, .col = @intCast(i % cols) };
                    p.term.grid().wrap_pending = false;
                },
                .selection => {
                    sel.begin(0, row);
                    sel.extend(@intCast(1 + i % (cols - 1)), row + 1);
                },
                .scroll => {
                    p.term.grid().cursor = .{ .row = rows - 1, .col = 0 };
                    p.term.grid().wrap_pending = false;
                    p.term.index();
                    p.term.printCodepoint(cp);
                },
                .resize => {},
            }
            const t0 = nowNs();
            if (case == .resize) {
                const c = cols + @as(u16, @intCast(1 - i % 2));
                try p.term.resize(c, rows);
                try p.frame.resize(@as(u32, c) * env.cell_w, @as(u32, rows) * env.cell_h);
            }
            p.frame.renderSel(&p.term, env.cell_w, env.cell_h, env.ctx, size_px, sel);
            const t1 = nowNs();
            std.mem.doNotOptimizeAway(p.frame.pixels);
            if ((case == .skip) == p.frame.damaged()) return error.UnexpectedDamage;
            p.term.clearDirty();
            if (i < 2) continue; // warm
            ns[i - 2] = t1 - t0;
            damage += if (p.frame.dirty_full) p.frame.height else p.frame.dirty_h;
        }
        const s = percentiles(ns);
        try log.print("  {s:<24} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.0}\n", .{ @tagName(case), s.p50 / 1000, s.p95 / 1000, s.mean / 1000, @as(f64, @floatFromInt(damage)) / @as(f64, @floatFromInt(samples)) });
    }
    try p.term.resize(cols, rows);
    try p.frame.resize(@as(u32, cols) * env.cell_w, @as(u32, rows) * env.cell_h);
    for (0..samples) |i| {
        const t0 = nowNs();
        @memcpy(p.present, p.frame.pixels);
        std.mem.doNotOptimizeAway(p.present);
        ns[i] = nowNs() - t0;
    }
    const s = percentiles(ns);
    try log.print("  {s:<24} {d:>10.1} {d:>10.1} {d:>10.1}  {d:.0} MiB/s\n", .{ "present copy", s.p50 / 1000, s.p95 / 1000, s.mean / 1000, @as(f64, @floatFromInt(p.present.len * 4)) / (s.p50 / 1e9) / (1024 * 1024) });
}

fn fillScreen(term: *VtState) void {
    term.reset();
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789  ";
    var r: u16 = 0;
    while (r < term.rows) : (r += 1) {
        term.grid().cursor = .{ .row = r, .col = 0 };
        term.grid().wrap_pending = false;
        var c: u16 = 0;
        while (c < term.cols) : (c += 1) term.printCodepoint(alphabet[(@as(usize, r) * 7 + c) % alphabet.len]);
    }
    term.grid().cursor = .{};
    term.grid().wrap_pending = false;
}

// ---------------------------------------------------------------- environment

fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn hashTerm(term: *const VtState) u64 {
    var h: u64 = 0;
    var r: u16 = 0;
    while (r < term.rows) : (r += 1) h = (h *% 0x100000001b3) ^ hashBytes(std.mem.sliceAsBytes(term.rowCells(r)));
    const c = term.cursor();
    return h ^ (@as(u64, c.row) << 32) ^ c.col;
}

const Font = struct { path: []u8, bytes: []u8 };

fn loadFonts(io: std.Io, gpa: std.mem.Allocator, override: ?[]const u8, out: *std.ArrayList(Font)) !void {
    if (override) |path| {
        const bytes = loadFile(io, gpa, path) catch |err| {
            std.debug.print("bench: font {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        try out.append(gpa, .{ .path = try gpa.dupe(u8, path), .bytes = bytes });
    } else if (fcMatch(io, gpa, "monospace")) |path| {
        if (loadFile(io, gpa, path)) |bytes| {
            try out.append(gpa, .{ .path = path, .bytes = bytes });
        } else |_| gpa.free(path);
    }
    if (out.items.len == 0) for (font_paths) |path| {
        const bytes = loadFile(io, gpa, path) catch continue;
        try out.append(gpa, .{ .path = try gpa.dupe(u8, path), .bytes = bytes });
        break;
    };
    if (out.items.len == 0) return;
    for (fallback_paths) |path| {
        if (std.mem.eql(u8, path, out.items[0].path)) continue;
        const bytes = loadFile(io, gpa, path) catch continue;
        try out.append(gpa, .{ .path = try gpa.dupe(u8, path), .bytes = bytes });
    }
}

fn fcMatch(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8) ?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "fc-match", "-f", "%{file}", pattern },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0 or path[0] != '/') return null;
    return gpa.dupe(u8, path) catch null;
}

fn loadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    if (len > 64 * 1024 * 1024) return error.FileTooLarge;
    const bytes = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ShortRead;
    return bytes;
}

fn readSmall(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    // procfs/sysfs report length zero; use a bounded positional read.
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn machineInfo(log: *Log, gpa: std.mem.Allocator, io: std.Io) !void {
    const data = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(data);
    const cpu = readSmall(io, "/proc/cpuinfo", data) orelse "";
    var model: []const u8 = "unknown";
    var lines = std.mem.splitScalar(u8, cpu, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "model name") or std.mem.startsWith(u8, line, "Hardware")) {
        model = std.mem.trim(u8, line[(std.mem.indexOfScalar(u8, line, ':') orelse 0) + 1 ..], " \t");
        break;
    };
    try log.print("host cpu {s} threads={d}\n", .{ model, std.Thread.getCpuCount() catch 0 });
    // Power state moves results by 1.5x+ on laptops; record it with every log.
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined;
    var ac: []const u8 = "unknown";
    for ([_][]const u8{ "/sys/class/power_supply/AC/online", "/sys/class/power_supply/ACAD/online", "/sys/class/power_supply/AC0/online", "/sys/class/power_supply/ADP1/online" }) |path| {
        if (readSmall(io, path, &b1)) |v| {
            ac = if (std.mem.eql(u8, v, "1")) "ac" else "battery";
            break;
        }
    }
    try log.print("power {s} governor={s} profile={s}\n", .{
        ac,
        readSmall(io, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", &b2) orelse "unknown",
        readSmall(io, "/sys/firmware/acpi/platform_profile", &b3) orelse "unknown",
    });
}

const Stamp = struct { iso: [20]u8, file: [18]u8 };
fn stampForSeconds(secs: u64) !Stamp {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var stamp: Stamp = undefined;
    const iso = try std.fmt.bufPrint(&stamp.iso, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
    const file = try std.fmt.bufPrint(&stamp.file, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
    if (iso.len != stamp.iso.len or file.len != stamp.file.len) return error.InvalidStamp;
    return stamp;
}
fn utcStamp(io: std.Io) !Stamp {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return stampForSeconds(if (ns <= 0) 0 else @intCast(@divTrunc(ns, 1_000_000_000)));
}

const Git = struct { hash: []u8, status: []const u8 };
fn gitRev(gpa: std.mem.Allocator, io: std.Io) !Git {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" }, .stdout_limit = .limited(64), .stderr_limit = .limited(256) }) catch return .{ .hash = try gpa.dupe(u8, "unknown"), .status = "unknown" };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!success or text.len == 0) return .{ .hash = try gpa.dupe(u8, "unknown"), .status = "unknown" };
    for (text) |c| if (!std.ascii.isHex(c)) return error.InvalidGitHash;
    const hash = try gpa.dupe(u8, text);
    errdefer gpa.free(hash);
    const status = std.process.run(gpa, io, .{ .argv = &.{ "git", "status", "--porcelain" }, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(256) }) catch return .{ .hash = hash, .status = "unknown" };
    defer gpa.free(status.stdout);
    defer gpa.free(status.stderr);
    return .{ .hash = hash, .status = switch (status.term) {
        .exited => |code| if (code != 0) "unknown" else if (std.mem.trim(u8, status.stdout, " \t\r\n").len == 0) "clean" else "dirty",
        else => "unknown",
    } };
}

fn saveLog(io: std.Io, log: *Log, stamp: [18]u8, hash: []const u8, dirty: bool) !void {
    const cwd = std.Io.Dir.cwd();
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "bench/{s}-{s}{s}.txt", .{ stamp, hash, if (dirty) "-dirty" else "" });
    cwd.createDirPath(io, "bench") catch |err| {
        std.debug.print("bench: create bench/: {s}\n", .{@errorName(err)});
        return err;
    };
    const data = log.buffer.writer.buffered();
    cwd.writeFile(io, .{ .sub_path = name, .data = data }) catch |err| {
        std.debug.print("bench: save {s}: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    cwd.writeFile(io, .{ .sub_path = "last_bench", .data = data }) catch |err| {
        std.debug.print("bench: save last_bench (stamped log saved): {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("saved {s} and last_bench\n", .{name});
}

// ---------------------------------------------------------------- tests

test "benchmark UTC filename is 18 bytes, including leap day and midnight" {
    const epoch = try stampForSeconds(0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &epoch.iso);
    try std.testing.expectEqualStrings("1970-01-01T000000Z", &epoch.file);
    const leap = try stampForSeconds(1709251199);
    try std.testing.expectEqualStrings("2024-02-29T235959Z", &leap.file);
    const next = try stampForSeconds(1709251200);
    try std.testing.expectEqualStrings("2024-03-01T000000Z", &next.file);
}

test "benchmark options validate and quick defaults respect explicit values" {
    const opt = try parseOptions(&.{ "bench", "--samples=50", "--quick", "--grid", "80x24", "--only=ascii,glyph", "--burst=4" });
    try std.testing.expectEqual(@as(u32, 50), opt.samples);
    try std.testing.expectEqual(@as(u32, 1), opt.mib);
    try std.testing.expectEqual(@as(u16, 80), opt.cols);
    try std.testing.expectEqual(@as(u16, 24), opt.rows);
    try std.testing.expectEqual(@as(u32, 4), opt.burst_kib);
    try std.testing.expect(wanted(opt, "glyph") and !wanted(opt, "sixel"));
    try std.testing.expectError(error.InvalidCount, parseOptions(&.{ "bench", "--samples=5" }));
    try std.testing.expectError(error.InvalidCount, parseOptions(&.{ "bench", "--burst=64" }));
    try std.testing.expectError(error.InvalidGrid, parseOptions(&.{ "bench", "--grid=80" }));
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{ "bench", "--typo=1" }));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{ "bench", "--font" }));
    try std.testing.expectError(error.UnexpectedValue, parseOptions(&.{ "bench", "--help=1" }));
}

test "benchmark percentiles are nearest-rank" {
    var v = [_]u64{ 5, 1, 4, 2, 3, 6, 7, 8, 9, 10 };
    const p = percentiles(&v);
    try std.testing.expectEqual(@as(f64, 5), p.p50);
    try std.testing.expectEqual(@as(f64, 10), p.p95);
    try std.testing.expectEqual(@as(f64, 5.5), p.mean);
    var one = [_]u64{7};
    try std.testing.expectEqual(@as(f64, 7), percentiles(&one).p95);
}

test "benchmark workloads parse completely and images reach the store" {
    const gpa = std.testing.allocator;
    for (workloads) |wl| {
        const bytes = try generate(gpa, wl, 128 * 1024);
        defer gpa.free(bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0x1b) != null);
        var ring = try CircBuffer.create(gpa, ring_cap);
        defer ring.destroy();
        var term = try VtState.init(gpa, 80, 24, scrollback, ring.storage);
        defer term.deinit();
        // Feed in 4093-byte cuts so sequences split across reads, as over a PTY.
        var off: usize = 0;
        while (off < bytes.len) {
            const n = @min(4093, bytes.len - off);
            const at: usize = @intCast(ring.head & (ring.capacity - 1));
            @memcpy(ring.storage[at..][0..n], bytes[off..][0..n]);
            if (!ring.mapped) mirror(&ring, at, n);
            ring.head += n;
            off += n;
            term.feedRuns(ring.consumeAndGetRuns(std.math.maxInt(usize)));
        }
        try std.testing.expectEqual(ring.head, ring.tail);
        if (std.mem.eql(u8, wl.name, "kitty-image") or std.mem.eql(u8, wl.name, "sixel")) {
            try std.testing.expect(term.kitty.images.items.len != 0);
        }
    }
}

test "benchmark PTY pipeline delivers every byte" {
    const gpa = std.testing.allocator;
    const bytes = try generate(gpa, workloads[0], 256 * 1024);
    defer gpa.free(bytes);
    var env: Env = .{ .gpa = gpa, .io = std.Io.Threaded.global_single_threaded.io(), .opt = .{ .cols = 40, .rows = 10 }, .ctx = null, .cell_w = 8, .cell_h = 16, .emoji = false };
    var log: Log = .{ .buffer = .init(gpa), .echo = false };
    defer log.buffer.deinit();
    try runPipeline(&log, &env, workloads[0], bytes);
    try std.testing.expect(std.mem.indexOf(u8, log.buffer.writer.buffered(), "pipeline ascii") != null);
}

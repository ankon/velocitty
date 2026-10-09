//! Headless, synthetic CPU benchmarks. No window, PTY drain, or compositor latency.
//! `zig build bench -- --quick`; see --help for sampling controls.
const std = @import("std");
const builtin = @import("builtin");
const CircBuffer = @import("circbuffer.zig").CircBuffer;
const VtState = @import("vt.zig").VtState;
const Draw = @import("draw.zig");
const Type = @import("type.zig");
const Select = @import("select.zig");
const EastAsian = @import("type/eastasian.zig");

const ring_cap = 64 * 1024;
const size_px: f32 = 16;
const font_paths = [_][]const u8{
    "/usr/share/fonts/iosevka-term/IosevkaTermNerdFontMono-Regular.ttf",
    "/usr/share/fonts/iosevka-term/IosevkaTermNerdFont-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf",
};
const lru_cps = [_]u21{ 0xA9, 0xAE, 0xB0, 0xB1, 0xD7, 0xF7, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x20AC, 0x2190, 0x2191, 0x2192 };

const Options = struct {
    quick: bool = false,
    samples: u32 = 5,
    warmup: u32 = 1,
    iterations: u32 = 10,
    font: ?[]const u8 = null,
    help: bool = false,
};

const usage =
    \\Usage: zig build bench -- [--quick] [--samples N] [--warmup N]
    \\                         [--iterations N] [--font PATH] [--help]
    \\  samples: measured batches (1..100; default 5)
    \\  warmup:  discarded batches (0..100; default 1)
    \\  iterations: operations per batch (1..10000; default 10)
    \\  quick: defaults to 3 samples, 1 warmup, 2 iterations; large frames use
    \\         one iteration per batch (normal: ceil(iterations / 5)).
    \\  Explicit counts override quick defaults, regardless of argument order.
    \\  Both --name=value and --name value are accepted. Unknown/duplicate
    \\  options and malformed values fail. Explicit font errors are fatal.
    \\  Without a font, CPU parsing/VT and placeholder rendering still run;
    \\  glyph/raster/atlas benchmarks are explicitly skipped.
    \\  Logs: bench/<UTC>-<git12>[-dirty].txt and last_bench in the current dir.
    \\  Metrics are sample-batch averages, not individual-frame latency tails.
    \\  These are headless CPU costs, not PTY/compositor/input latency or FPS.
    \\
;

fn parseOptions(args: []const [*:0]const u8) !Options {
    var opt: Options = .{};
    var seen: u8 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[0 .. eq orelse arg.len];
        const bit: u8 = if (std.mem.eql(u8, name, "--quick")) 1 else if (std.mem.eql(u8, name, "--samples")) 2 else if (std.mem.eql(u8, name, "--warmup")) 4 else if (std.mem.eql(u8, name, "--iterations")) 8 else if (std.mem.eql(u8, name, "--font")) 16 else if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) 32 else return error.UnknownOption;
        if (seen & bit != 0) return error.DuplicateOption;
        seen |= bit;
        if (bit == 1 or bit == 32) {
            if (eq != null) return error.UnexpectedValue;
            if (bit == 1) opt.quick = true else opt.help = true;
            continue;
        }
        const value: []const u8 = if (eq) |at| arg[at + 1 ..] else blk: {
            i += 1;
            if (i == args.len) return error.MissingValue;
            break :blk std.mem.span(args[i]);
        };
        if (value.len == 0) return error.MissingValue;
        if (bit == 16) {
            if (std.mem.startsWith(u8, value, "--")) return error.MissingValue;
            opt.font = value;
        } else {
            for (value) |c| if (c < '0' or c > '9') return error.InvalidCount;
            const n = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCount;
            const max: u32 = if (bit == 8) 10000 else 100;
            if (n > max or (n == 0 and bit != 4)) return error.InvalidCount;
            switch (bit) {
                2 => opt.samples = n,
                4 => opt.warmup = n,
                8 => opt.iterations = n,
                else => unreachable,
            }
        }
    }
    if (opt.quick) {
        if (seen & 2 == 0) opt.samples = 3;
        if (seen & 8 == 0) opt.iterations = 2;
    }
    return opt;
}

const Log = struct {
    buffer: std.Io.Writer.Allocating,
    fn print(self: *Log, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
        try self.buffer.writer.print(fmt, args);
    }
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
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var log: Log = .{ .buffer = .init(allocator) };
    defer log.buffer.deinit();
    const stamp = try utcStamp(io);
    const git = try gitRev(allocator, io);
    defer allocator.free(git.hash);
    try log.print("velocitty headless CPU benchmark v2\nutc {s}\ngit {s} status={s}\n", .{ stamp.iso, git.hash, git.status });
    try log.print("compiler Zig {s} optimize={s} target={s}-{s}-{s} cpu-target={s}\n", .{
        builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi), builtin.cpu.model.name,
    });
    try machineInfo(&log, allocator, io);
    try log.print("settings quick={} samples={d} warmup={d} iterations={d} ring={d} size_px={d} workload=deterministic-v2 (no random seed)\n", .{
        opt.quick, opt.samples, opt.warmup, opt.iterations, ring_cap, size_px,
    });
    try log.print("clock=monotonic awake; min/median/p95/max and spread=(max-min)/median are batch-average ns/op.\nSetup/reset/checksums excluded; timing, memory barriers and loop bookkeeping included.\nNo PTY/readPTY, Peak, scheduling, GPU/compositor, or input-to-echo measured.\nByte rates describe the named input/copy domain, never painted bytes for skip/dirty frames.\n\n", .{});

    const font = try loadFont(io, allocator, opt.font);
    defer if (font) |f| allocator.free(f.bytes);
    var ctx: ?Type.Context = null;
    defer if (ctx) |*c| c.deinit();
    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    if (font) |f| {
        ctx = try Type.Context.init(allocator, .{});
        const c = &ctx.?;
        _ = try c.addFont(f.bytes, .{});
        const metrics = try c.metrics(size_px);
        const height = @ceil(metrics.ascender - metrics.descender + metrics.line_gap);
        const glyph = try c.glyph('M', size_px);
        const width = @ceil(glyph.advance);
        // Validate before converting: bad float-to-int is UB in ReleaseFast.
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0 or width > 256 or height > 256) return error.InvalidFontMetrics;
        cell_h = @intFromFloat(height);
        cell_w = @intFromFloat(width);
        try log.print("font {s} bytes={d} hash={x} cell={d}x{d}; regular face only, no shaping/fallback faces\n", .{ f.path, f.bytes.len, hashBytes(f.bytes), cell_w, cell_h });
    } else {
        try log.print("font NONE: placeholder render, glyph/raster/atlas SKIPPED\n", .{});
    }
    const type_ctx: ?*Type.Context = if (ctx) |*c| c else null;
    var work = try Work.init(allocator, io, 80, 24, cell_w, cell_h, type_ctx);
    defer work.deinit();
    try log.print("ring mirrored={}; screen=80x24 framebuffer={d}x{d}\n", .{ work.ring.mapped, work.frame.width, work.frame.height });

    const corpora = [_]struct { name: []const u8, unit: []const u8 }{
        .{ .name = "ASCII", .unit = "abcdefghijklmnopqrstuvwxyz 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n" },
        .{ .name = "controls", .unit = "\x1b[32mgreen\x1b[0m text\tend\r\n\x1b[2K\x1b[1G\x1b[4munderlined\x1b[0m\r\n" },
        .{ .name = "mixed-UTF8", .unit = "ASCII 汉字测试 あア 한 café © →\r\n" },
    };
    for (corpora) |corpus| {
        const payload = try makePayload(allocator, corpus.unit);
        defer allocator.free(payload);
        work.payload = payload;
        work.loadPayload();
        try log.print("\ninput {s}: corpus/raw={d} B; parse/VT start with all bytes retained, no loss\n", .{ corpus.name, payload.len });
        try run(&log, opt, &work, .ingest, "synthetic ring overwrite copy", .bytes, payload.len, opt.iterations);
        try run(&log, opt, &work, .lines, "line scan all input", .bytes, payload.len, opt.iterations);
        try run(&log, opt, &work, .runs_all, "split runs all lines", .bytes, payload.len, opt.iterations);
        work.loadPayload();
        work.ring.consumeAndPreparse();
        work.ring.splitIntoRuns(work.ring.getLastNLines(24));
        const selected = runBytes(&work.ring);
        try log.print("last-24 experiment: scanned={d} selected/feed={d} B; NOT runtime semantics\n", .{ payload.len, selected });
        try run(&log, opt, &work, .runs_last, "split runs selected last-24", .bytes, selected, opt.iterations);
        try run(&log, opt, &work, .parse_all, "scan+split all input", .bytes, payload.len, opt.iterations);
        try run(&log, opt, &work, .parse_last, "scan+split last-24 (scanned B)", .bytes, payload.len, opt.iterations);
        try run(&log, opt, &work, .vt_all, "VT feed all (reset excluded)", .bytes, payload.len, opt.iterations);
        try run(&log, opt, &work, .vt_last, "VT feed selected last-24", .bytes, selected, opt.iterations);
        try run(&log, opt, &work, .pipeline, "ingest->all VT->render->copy", .bytes, payload.len, opt.iterations);
        try log.print("  pipeline/pass raw={d} fed={d} scanned={d} dropped=0 final-unread={d} max-retained={d} chunks={d} renders/copies={d}\n", .{
            payload.len, work.pipeline_fed, work.pipeline_scanned, work.ring.head - work.ring.tail, work.max_unread, work.pipeline_chunks, work.pipeline_chunks,
        });
    }
    // Corpus allocations above are scoped to each loop iteration.
    work.payload = &.{};
    try log.print("\nlossy firehose: synthetic memcpy ingestion only; 4 MiB/op, 64 KiB retained, no parse/VT\n", .{});
    const firehose = try makePayload(allocator, "synthetic lossy firehose ring fill\r\n");
    defer allocator.free(firehose);
    work.payload = firehose;
    try run(&log, opt, &work, .firehose, "overrun ring ingest", .bytes, 4 * 1024 * 1024, opt.iterations);
    work.payload = &.{};
    try log.print("\nunicode width: queries, NOT bytes\n", .{});
    try run(&log, opt, &work, .width_ascii, "cellWidth ASCII", .queries, 128, opt.iterations);
    try run(&log, opt, &work, .width_bmp, "cellWidth U+0000..U+2FFF", .queries, 0x3000, opt.iterations);
    try run(&log, opt, &work, .width_cjk, "cellWidth CJK range", .queries, 4096, opt.iterations);

    try renderSuite(&log, opt, &work, opt.iterations);
    if (type_ctx != null) {
        try log.print("\nfonts: glyph queries (not coverage bandwidth); cache hits peek without refreshing LRU\n", .{});
        try run(&log, opt, &work, .glyph_ascii, "glyph hot ASCII table", .queries, 95, opt.iterations);
        try run(&log, opt, &work, .glyph_lru, "glyph hot non-ASCII cache", .queries, lru_cps.len, opt.iterations);
        try run(&log, opt, &work, .peek_lru, "peekGlyph non-ASCII cache", .queries, lru_cps.len, opt.iterations);
        try run(&log, opt, &work, .atlas_reset, "clearAtlas INCLUDING ASCII prewarm", .operations, 1, opt.iterations);
        try run(&log, opt, &work, .raster, "rasterize A incl alloc/free", .operations, 1, opt.iterations);
        try run(&log, opt, &work, .atlas, "atlas pack+blit A", .operations, 1, opt.iterations);
    }
    // Both representative large sizes run in quick mode, with bounded repetitions.
    const large_iters: u32 = if (opt.quick) 1 else @max(1, (opt.iterations + 4) / 5);
    const sizes = [_][2]u16{
        .{ 220, 60 },
        .{ @intCast(@max(1, 3840 / cell_w)), @intCast(@max(1, 2160 / cell_h)) },
    };
    for (sizes) |wh| {
        var large = try Work.init(allocator, io, wh[0], wh[1], cell_w, cell_h, type_ctx);
        defer large.deinit();
        try renderSuite(&log, opt, &large, large_iters);
    }
    try log.print("\nchecksum {x} (observable state/pixels; not a portable golden)\n", .{work.checksum});
    try saveLog(io, &log, stamp.file, git.hash, std.mem.eql(u8, git.status, "dirty"));
}

const Operation = enum {
    ingest,
    firehose,
    lines,
    runs_all,
    runs_last,
    parse_all,
    parse_last,
    vt_all,
    vt_last,
    pipeline,
    width_ascii,
    width_bmp,
    width_cjk,
    full,
    skip,
    single,
    line,
    cursor,
    selection,
    scroll,
    resize,
    copy,
    memset,
    glyph_ascii,
    glyph_lru,
    peek_lru,
    atlas_reset,
    raster,
    atlas,
};
const Metric = enum { bytes, queries, frames, operations };

const Work = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ring: CircBuffer,
    term: VtState,
    frame: Draw.Frame,
    copy_pixels: []u32,
    type_ctx: ?*Type.Context,
    cell_w: u32,
    cell_h: u32,
    base_cols: u16,
    base_rows: u16,
    payload: []const u8 = &.{},
    sel: Select.State = .{},
    checksum: u64 = 0,
    query_acc: u64 = 0,
    pipeline_fed: usize = 0,
    pipeline_scanned: u64 = 0,
    pipeline_chunks: usize = 0,
    max_unread: u64 = 0,
    bitmap: ?Type.TrueType.Bitmap = null,
    atlas: ?Type.Atlas = null,
    glyph_id: u16 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, cols: u16, rows: u16, cw: u32, ch: u32, ctx: ?*Type.Context) !Work {
        var ring = try CircBuffer.create(allocator, ring_cap);
        errdefer ring.destroy();
        var term = try VtState.init(allocator, cols, rows, @max(1000, @as(u32, rows) * 2), ring.storage);
        errdefer term.deinit();
        var frame = try Draw.Frame.init(allocator, @as(u32, cols) * cw, @as(u32, rows) * ch);
        errdefer frame.deinit();
        const copy_pixels = try allocator.alloc(u32, frame.pixels.len);
        @memset(copy_pixels, 0);
        return .{ .allocator = allocator, .io = io, .ring = ring, .term = term, .frame = frame, .copy_pixels = copy_pixels, .type_ctx = ctx, .cell_w = cw, .cell_h = ch, .base_cols = cols, .base_rows = rows };
    }

    fn deinit(self: *Work) void {
        if (self.bitmap) |bmp| self.allocator.free(bmp.pixels);
        if (self.atlas) |*a| a.deinit();
        self.allocator.free(self.copy_pixels);
        self.frame.deinit();
        self.term.deinit();
        self.ring.destroy();
    }

    fn loadPayload(self: *Work) void {
        self.ring.head = 0;
        self.ring.tail = 0;
        self.ring.hold_at_head = 0;
        ingest(&self.ring, self.payload);
    }

    fn prepare(self: *Work, op: Operation) !void {
        self.sel = .{};
        self.query_acc = 0;
        self.loadPayload();
        switch (op) {
            .runs_all, .runs_last => self.ring.consumeAndPreparse(),
            .vt_all, .vt_last => {
                _ = self.ring.consumeAndGetRuns(if (op == .vt_last) 24 else std.math.maxInt(usize));
            },
            .pipeline => {
                self.ring.head = 0;
                self.ring.tail = 0;
                self.term.reset();
                self.frame.invalidate();
            },
            .full, .skip, .single, .line, .cursor, .selection, .scroll, .resize, .copy, .memset => {
                try self.term.resize(self.base_cols, self.base_rows);
                try self.frame.resize(@as(u32, self.base_cols) * self.cell_w, @as(u32, self.base_rows) * self.cell_h);
                fillScreen(&self.term);
                // Isolate dirty-cell/selection/scroll work from cursor movement.
                self.term.flags.cursor_visible = op == .cursor;
                self.frame.invalidate();
                self.frame.render(&self.term, self.cell_w, self.cell_h, self.type_ctx, size_px);
                self.term.clearDirty();
            },
            .glyph_ascii, .glyph_lru, .peek_lru, .atlas_reset, .raster, .atlas => {
                const ctx = self.type_ctx.?;
                var cp: u21 = 32;
                while (cp < 127) : (cp += 1) _ = try ctx.glyph(cp, size_px);
                for (lru_cps) |c| _ = try ctx.glyph(c, size_px);
                ctx.stats = .{};
                if (op == .raster or op == .atlas) {
                    const font = ctx.faces.items[0].font;
                    self.glyph_id = (try font.glyphIndex('A')) orelse return error.GlyphNotFound;
                    if (self.bitmap == null) self.bitmap = try font.rasterize(self.allocator, self.glyph_id, size_px);
                    if (self.bitmap.?.width == 0 or self.bitmap.?.height == 0 or self.bitmap.?.color) return error.InvalidRasterBitmap;
                    if (self.atlas == null) self.atlas = try Type.Atlas.init(self.allocator, 1024, 1024);
                    self.atlas.?.clear();
                }
            },
            else => {},
        }
    }

    // Mutations/reset are excluded for isolated stages. resize and pipeline include
    // their mutations, allocations/reflow, and render/copy in the timed operation.
    fn prepareIteration(self: *Work, op: Operation, i: u32) void {
        const cp: u21 = if (i % 2 == 0) '#' else '@';
        switch (op) {
            .lines, .parse_all, .parse_last => {
                self.ring.tail = 0;
                self.ring.hold_at_head = 0;
            },
            .vt_all, .vt_last => self.term.reset(),
            .full => {
                self.frame.invalidate();
                self.term.markDirtyAll();
            },
            .skip, .single, .line, .cursor, .selection, .scroll => {
                self.term.clearDirty();
                const row = self.term.rows / 2;
                if (op == .single or op == .line) {
                    self.term.grid().cursor = .{ .row = row, .col = 0 };
                    self.term.grid().wrap_pending = false;
                    const count: u16 = if (op == .single) 1 else self.term.cols;
                    var col: u16 = 0;
                    while (col < count) : (col += 1) self.term.printCodepoint(cp);
                } else if (op == .cursor) {
                    self.term.grid().cursor = .{ .row = row, .col = @intCast(i % self.term.cols) };
                    self.term.grid().wrap_pending = false;
                } else if (op == .selection) {
                    self.sel.begin(0, row);
                    self.sel.extend(@intCast(1 + i % (self.term.cols - 1)), row + 1);
                } else if (op == .scroll) {
                    // ESC D equivalent: one-row full-screen index followed by
                    // distinct new text. Cursor at bottom ensures real scrolling.
                    self.term.grid().cursor = .{ .row = self.term.rows - 1, .col = 0 };
                    self.term.grid().wrap_pending = false;
                    self.term.index();
                    self.term.printCodepoint(cp);
                }
            },
            .atlas => {
                const bmp = self.bitmap.?;
                const a = &self.atlas.?;
                // Capacity maintenance excluded from isolated pack+blit.
                if (a.shelf_y + a.shelf_h + bmp.height > a.height) a.clear();
            },
            else => {},
        }
    }

    fn perform(self: *Work, op: Operation, i: u32) !void {
        switch (op) {
            .ingest => {
                ingest(&self.ring, self.payload);
                std.mem.doNotOptimizeAway(self.ring.storage);
            },
            .firehose => {
                // Each copy observed; this deliberately retains only the last ring.
                var n: usize = 0;
                while (n < 4 * 1024 * 1024) {
                    const count = @min(self.payload.len, 4 * 1024 * 1024 - n);
                    ingest(&self.ring, self.payload[0..count]);
                    std.mem.doNotOptimizeAway(self.ring.storage);
                    n += count;
                }
            },
            .lines => self.ring.consumeAndPreparse(),
            .runs_all => self.ring.splitIntoRuns(self.ring.lines.items),
            .runs_last => self.ring.splitIntoRuns(self.ring.getLastNLines(24)),
            .parse_all, .parse_last => {
                _ = self.ring.consumeAndGetRuns(if (op == .parse_last) 24 else std.math.maxInt(usize));
            },
            .vt_all, .vt_last => self.term.feedRuns(self.ring.runs.items),
            .pipeline => try self.pipeline(),
            .width_ascii, .width_bmp, .width_cjk => {
                var cp: u21 = if (op == .width_cjk) 0x4E00 else 0;
                const end: u21 = switch (op) {
                    .width_ascii => 128,
                    .width_bmp => 0x3000,
                    else => 0x4E00 + 4096,
                };
                // Prevent loop-invariant constant-query elimination/hoisting.
                while (cp < end) : (cp += 1) {
                    std.mem.doNotOptimizeAway(&cp);
                    self.query_acc +%= EastAsian.cellWidth(cp);
                }
            },
            .full, .skip, .single, .line, .cursor, .selection, .scroll => {
                self.frame.renderSel(&self.term, self.cell_w, self.cell_h, self.type_ctx, size_px, self.sel);
                std.mem.doNotOptimizeAway(self.frame.pixels);
            },
            .resize => {
                const cols = self.base_cols + @as(u16, @intCast(1 - i % 2));
                try self.term.resize(cols, self.base_rows);
                try self.frame.resize(@as(u32, cols) * self.cell_w, @as(u32, self.base_rows) * self.cell_h);
                self.frame.render(&self.term, self.cell_w, self.cell_h, self.type_ctx, size_px);
                self.term.clearDirty();
                std.mem.doNotOptimizeAway(self.frame.pixels);
            },
            .copy => {
                @memcpy(self.copy_pixels, self.frame.pixels);
                std.mem.doNotOptimizeAway(self.copy_pixels);
            },
            .memset => {
                @memset(self.frame.pixels, i);
                std.mem.doNotOptimizeAway(self.frame.pixels);
            },
            .glyph_ascii => {
                var cp: u21 = 32;
                while (cp < 127) : (cp += 1) {
                    std.mem.doNotOptimizeAway(&cp);
                    const g = try self.type_ctx.?.glyph(cp, size_px);
                    self.query_acc +%= g.glyph_id;
                    std.mem.doNotOptimizeAway(g);
                }
            },
            .glyph_lru, .peek_lru => {
                for (lru_cps) |codepoint| {
                    var cp = codepoint;
                    std.mem.doNotOptimizeAway(&cp);
                    const g = if (op == .glyph_lru) try self.type_ctx.?.glyph(cp, size_px) else self.type_ctx.?.peekGlyph(cp, size_px) orelse return error.CacheNotWarm;
                    self.query_acc +%= g.glyph_id;
                    std.mem.doNotOptimizeAway(g);
                }
            },
            .atlas_reset => {
                self.type_ctx.?.clearAtlas();
                std.mem.doNotOptimizeAway(self.type_ctx.?.atlas.pixels);
            },
            .raster => {
                const bmp = try self.type_ctx.?.faces.items[0].font.rasterize(self.allocator, self.glyph_id, size_px);
                std.mem.doNotOptimizeAway(bmp.pixels);
                // Retain this output for a checksum after the timed batch;
                // allocation and freeing the previous same-sized bitmap are timed.
                self.allocator.free(self.bitmap.?.pixels);
                self.bitmap = bmp;
            },
            .atlas => {
                const bmp = self.bitmap.?;
                const a = &self.atlas.?;
                const rect = a.pack(bmp.width, bmp.height) orelse return error.AtlasFull;
                a.blit(rect, bmp.pixels);
                std.mem.doNotOptimizeAway(a.pixels);
            },
        }
        // A memory-clobbering barrier per operation makes writes observable even
        // when a later repetition replaces the same state. No full-frame hashing
        // is charged to render/copy timings.
        std.mem.doNotOptimizeAway(self);
    }

    fn pipeline(self: *Work) !void {
        self.pipeline_fed = 0;
        self.pipeline_scanned = 0;
        self.pipeline_chunks = 0;
        self.max_unread = 0;
        var off: usize = 0;
        while (off < self.payload.len) {
            // 4093 intentionally cuts CRLF/UTF8/controls at changing boundaries.
            const end = @min(off + 4093, self.payload.len);
            ingest(&self.ring, self.payload[off..end]);
            const unread = self.ring.head - self.ring.tail;
            if (unread > self.ring.capacity) return error.PipelineOverrun;
            self.max_unread = @max(self.max_unread, unread);
            self.pipeline_scanned += unread;
            const runs = self.ring.consumeAndGetRuns(std.math.maxInt(usize));
            self.pipeline_fed += runBytes(&self.ring);
            self.term.feedRuns(runs);
            self.frame.render(&self.term, self.cell_w, self.cell_h, self.type_ctx, size_px);
            self.term.clearDirty();
            @memcpy(self.copy_pixels, self.frame.pixels);
            std.mem.doNotOptimizeAway(self.copy_pixels);
            self.pipeline_chunks += 1;
            off = end;
        }
        if (self.pipeline_fed != self.payload.len or self.ring.tail != self.ring.head) return error.PipelineByteMismatch;
    }

    fn observe(self: *Work, op: Operation) void {
        var h: u64 = self.query_acc;
        switch (op) {
            .ingest, .firehose => {
                const start: usize = @intCast((self.ring.head - @min(self.ring.head, self.ring.capacity)) & (self.ring.capacity - 1));
                h ^= hashBytes(self.ring.storage[start..][0..@intCast(@min(self.ring.head, self.ring.capacity))]);
            },
            .lines => {
                for (self.ring.lines.items) |line| h = (h *% 16777619) ^ line.off ^ line.len;
            },
            .runs_all, .runs_last, .parse_all, .parse_last => {
                for (self.ring.runs.items) |r| h = (h *% 16777619) ^ r.off ^ r.len ^ @intFromEnum(r.kind);
            },
            .vt_all, .vt_last => h ^= hashTerm(&self.term),
            .pipeline => h ^= hashTerm(&self.term) ^ hashBytes(std.mem.sliceAsBytes(self.copy_pixels)),
            .copy => h ^= hashBytes(std.mem.sliceAsBytes(self.copy_pixels)),
            .full, .skip, .single, .line, .cursor, .selection, .scroll, .resize, .memset => h ^= hashBytes(std.mem.sliceAsBytes(self.frame.pixels)),
            .raster => h ^= hashBytes(self.bitmap.?.pixels),
            .atlas => h ^= hashBytes(self.atlas.?.pixels),
            .atlas_reset => h ^= hashBytes(self.type_ctx.?.atlas.pixels),
            else => {},
        }
        self.checksum = (self.checksum *% 0x100000001b3) ^ h;
        std.mem.doNotOptimizeAway(self.checksum);
    }
};

fn renderSuite(log: *Log, opt: Options, work: *Work, iterations: u32) !void {
    try log.print("\nrender {d}x{d}: framebuffer={d}x{d} ({d} B); {d} iterations/batch\n", .{
        work.base_cols, work.base_rows, work.frame.width, work.frame.height, work.frame.pixels.len * 4, iterations,
    });
    try log.print("  Warm glyph cache/snapshot; cursor hidden except cursor case. Dirty scenarios mutate before timing; resize includes reflow/alloc/render.\n  Damage is a bounding band, NOT exact painted pixel bytes.\n", .{});
    const cases = [_]struct { op: Operation, name: []const u8 }{
        .{ .op = .full, .name = "full repaint (invalidate)" },
        .{ .op = .skip, .name = "no-change render" },
        .{ .op = .single, .name = "single-cell dirty render" },
        .{ .op = .line, .name = "one-line dirty render" },
        .{ .op = .cursor, .name = "cursor-move render" },
        .{ .op = .selection, .name = "selection-change render" },
        .{ .op = .scroll, .name = "one-row scroll render" },
        .{ .op = .resize, .name = "resize +/-1 col + render" },
    };
    for (cases) |case| try run(log, opt, work, case.op, case.name, .frames, 1, iterations);
    // Resize changes frame length; restore it before the fixed-size copy tests.
    try work.term.resize(work.base_cols, work.base_rows);
    try work.frame.resize(@as(u32, work.base_cols) * work.cell_w, @as(u32, work.base_rows) * work.cell_h);
    try run(log, opt, work, .copy, "CPU framebuffer memcpy", .bytes, work.copy_pixels.len * 4, iterations);
    try run(log, opt, work, .memset, "CPU framebuffer memset", .bytes, work.copy_pixels.len * 4, iterations);
    try log.print("  render-suite checksum={x}\n", .{work.checksum});
}

const Summary = struct { min: f64, median: f64, p95: f64, max: f64 };
fn summarize(values: []f64) Summary {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const n = values.len;
    return .{
        .min = values[0],
        .median = if (n % 2 == 0) (values[n / 2 - 1] + values[n / 2]) / 2 else values[n / 2],
        .p95 = values[(n * 95 + 99) / 100 - 1],
        .max = values[n - 1],
    };
}

fn run(log: *Log, opt: Options, work: *Work, op: Operation, name: []const u8, metric: Metric, units: usize, iterations: u32) !void {
    var samples: [100]f64 = undefined;
    var damage: u64 = 0;
    var fill_ns: u64 = 0;
    var glyph_ns: u64 = 0;
    var batch: u32 = 0;
    while (batch < opt.warmup + opt.samples) : (batch += 1) {
        try work.prepare(op);
        var elapsed: i128 = 0;
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            work.prepareIteration(op, i);
            const start = nowNs(work.io);
            try work.perform(op, i);
            elapsed += nowNs(work.io) - start;
            // Reject incomplete/failed descriptor construction outside the timer.
            switch (op) {
                .lines => {
                    var scanned: usize = 0;
                    for (work.ring.lines.items) |line| scanned += line.len;
                    if (scanned != units) return error.LineByteMismatch;
                },
                .runs_all, .runs_last, .parse_all, .vt_all, .vt_last => {
                    if (runBytes(&work.ring) != units) return error.RunByteMismatch;
                },
                .parse_last => try validateParseLast(work, units),
                .atlas_reset => {
                    for (work.type_ctx.?.ascii) |glyph| if (glyph == null) return error.IncompleteAsciiPrewarm;
                },
                else => {},
            }
            if (batch >= opt.warmup and metric == .frames) {
                damage += if (work.frame.dirty_full) work.frame.height else work.frame.dirty_h;
                fill_ns += work.frame.last_fill_ns;
                glyph_ns += work.frame.last_glyph_ns;
                if (op == .skip and work.frame.damaged()) return error.SkipFrameDamaged;
                if (op != .skip and !work.frame.damaged()) return error.DirtyFrameNotDamaged;
            }
        }
        work.observe(op);
        if (batch >= opt.warmup) samples[batch - opt.warmup] = @as(f64, @floatFromInt(@max(elapsed, 1))) / @as(f64, @floatFromInt(iterations));
    }
    const stats = summarize(samples[0..opt.samples]);
    const spread = (stats.max - stats.min) / stats.median * 100;
    const divisor: f64 = if (metric == .queries) @floatFromInt(units) else 1;
    const scale: f64 = if (metric == .queries) 1 else 1_000_000;
    try log.print("  {s}\n    min={d:.6} median={d:.6} p95={d:.6} max={d:.6} {s} spread={d:.1}%", .{
        name,                                                                                   stats.min / divisor / scale, stats.median / divisor / scale, stats.p95 / divisor / scale, stats.max / divisor / scale,
        if (metric == .queries) "ns/query" else if (metric == .frames) "ms/frame" else "ms/op", spread,
    });
    if (metric == .bytes) try log.print(" input/copy={d} B/op median={d:.2} MiB/s", .{ units, @as(f64, @floatFromInt(units)) / stats.median * 1_000_000_000 / (1024 * 1024) });
    if (metric == .queries) try log.print(" queries={d}/op median={d:.2} Mquery/s", .{ units, @as(f64, @floatFromInt(units)) / stats.median * 1000 });
    try log.print(" checksum={x}\n", .{work.checksum});
    if (metric == .frames) {
        const count: f64 = @floatFromInt(opt.samples * iterations);
        try log.print("    mean damage-band={d:.1} pixel-rows/frame fill={d:.3} glyph={d:.3} ms/frame\n", .{
            @as(f64, @floatFromInt(damage)) / count, @as(f64, @floatFromInt(fill_ns)) / count / 1_000_000, @as(f64, @floatFromInt(glyph_ns)) / count / 1_000_000,
        });
    }
    if (op == .glyph_ascii or op == .glyph_lru) {
        const stats_g = work.type_ctx.?.stats;
        try log.print("    last batch hits={d} misses={d} (missing codepoints may use replacement glyph)\n", .{ stats_g.hits, stats_g.misses });
    }
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

fn makePayload(allocator: std.mem.Allocator, unit: []const u8) ![]u8 {
    const n = ring_cap / unit.len * unit.len;
    const payload = try allocator.alloc(u8, n);
    var off: usize = 0;
    while (off < n) : (off += unit.len) @memcpy(payload[off..][0..unit.len], unit);
    return payload;
}

// Same write/mirror contract as readPTYPump, but explicitly synthetic memory IO.
fn ingest(buf: *CircBuffer, src: []const u8) void {
    var rest = src;
    while (rest.len != 0) {
        const off: usize = @intCast(buf.head & (buf.capacity - 1));
        const n = @min(buf.capacity, rest.len);
        @memcpy(buf.storage[off..][0..n], rest[0..n]);
        if (!buf.mapped) {
            const first = @min(n, buf.capacity - off);
            @memcpy(buf.storage[off + buf.capacity ..][0..first], buf.storage[off..][0..first]);
            const extra = n - first;
            @memcpy(buf.storage[0..extra], buf.storage[buf.capacity..][0..extra]);
        }
        buf.head += n;
        rest = rest[n..];
    }
}

fn runBytes(buf: *const CircBuffer) usize {
    var n: usize = 0;
    for (buf.runs.items) |r| n += r.len;
    return n;
}
fn validateParseLast(work: *const Work, scanned_units: usize) !void {
    var scanned: usize = 0;
    for (work.ring.lines.items) |line| scanned += line.len;
    if (scanned != scanned_units) return error.LineByteMismatch;
    var selected: usize = 0;
    for (work.ring.getLastNLines(24)) |line| selected += line.len;
    if (runBytes(&work.ring) != selected) return error.SelectedRunByteMismatch;
}
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
fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

const Font = struct { path: []const u8, bytes: []u8 };
fn loadFont(io: std.Io, allocator: std.mem.Allocator, override: ?[]const u8) !?Font {
    if (override) |path| return .{ .path = path, .bytes = loadFile(io, allocator, path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("bench: font {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    } };
    for (font_paths) |path| {
        const bytes = loadFile(io, allocator, path, 64 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                std.debug.print("bench: font candidate {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            },
        };
        return .{ .path = path, .bytes = bytes };
    }
    return null;
}
fn loadFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    if (len > limit) return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ShortRead;
    return bytes;
}

fn machineInfo(log: *Log, allocator: std.mem.Allocator, io: std.Io) !void {
    // procfs files report length zero, so use a bounded positional read.
    const file = std.Io.Dir.openFileAbsolute(io, "/proc/cpuinfo", .{}) catch |err| {
        try log.print("cpu info unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer file.close(io);
    const data = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(data);
    const n = file.readPositionalAll(io, data, 0) catch |err| {
        try log.print("cpu info unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    var lines = std.mem.splitScalar(u8, data[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name") or std.mem.startsWith(u8, line, "Hardware")) {
            try log.print("host cpu {s}\n", .{line});
            return;
        }
    }
    try log.print("host cpu model unavailable; compare only under similar load/power policy\n", .{});
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
fn gitRev(allocator: std.mem.Allocator, io: std.Io) !Git {
    const result = std.process.run(allocator, io, .{ .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" }, .stdout_limit = .limited(64), .stderr_limit = .limited(256) }) catch return .{ .hash = try allocator.dupe(u8, "unknown"), .status = "unknown" };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!success or text.len == 0) return .{ .hash = try allocator.dupe(u8, "unknown"), .status = "unknown" };
    for (text) |c| if (!std.ascii.isHex(c)) return error.InvalidGitHash;
    const hash = try allocator.dupe(u8, text);
    errdefer allocator.free(hash);
    const status = std.process.run(allocator, io, .{ .argv = &.{ "git", "status", "--porcelain" }, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(256) }) catch return .{ .hash = hash, .status = "unknown" };
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);
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

test "benchmark UTC filename is 18 bytes, including leap day and midnight" {
    const epoch = try stampForSeconds(0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &epoch.iso);
    try std.testing.expectEqualStrings("1970-01-01T000000Z", &epoch.file);
    const leap = try stampForSeconds(1709251199);
    try std.testing.expectEqualStrings("2024-02-29T23:59:59Z", &leap.iso);
    try std.testing.expectEqualStrings("2024-02-29T235959Z", &leap.file);
    const next = try stampForSeconds(1709251200);
    try std.testing.expectEqualStrings("2024-03-01T000000Z", &next.file);
}
test "benchmark options validate and quick defaults respect explicit counts" {
    const opt = try parseOptions(&.{ "bench", "--iterations=7", "--quick", "--samples", "1", "--warmup=0", "--font=font.ttf" });
    try std.testing.expectEqual(@as(u32, 7), opt.iterations);
    try std.testing.expectEqual(@as(u32, 1), opt.samples);
    try std.testing.expectEqual(@as(u32, 0), opt.warmup);
    try std.testing.expectEqualStrings("font.ttf", opt.font.?);
    const quick = try parseOptions(&.{ "bench", "--quick" });
    try std.testing.expectEqual(@as(u32, 2), quick.iterations);
    try std.testing.expectEqual(@as(u32, 3), quick.samples);
    try std.testing.expectError(error.InvalidCount, parseOptions(&.{ "bench", "--samples=0" }));
    try std.testing.expectError(error.InvalidCount, parseOptions(&.{ "bench", "--iterations=-1" }));
    try std.testing.expectError(error.InvalidCount, parseOptions(&.{ "bench", "--samples=101" }));
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{ "bench", "--typo" }));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{ "bench", "--font" }));
    try std.testing.expectError(error.DuplicateOption, parseOptions(&.{ "bench", "--quick", "--quick" }));
    try std.testing.expectError(error.UnexpectedValue, parseOptions(&.{ "bench", "--help=1" }));
}
test "benchmark summary uses interpolated median and nearest-rank tail" {
    var values = [_]f64{ 4, 1, 3, 2 };
    const s = summarize(&values);
    try std.testing.expectEqual(@as(f64, 1), s.min);
    try std.testing.expectEqual(@as(f64, 2.5), s.median);
    try std.testing.expectEqual(@as(f64, 4), s.p95);
    try std.testing.expectEqual(@as(f64, 4), s.max);
}

test "last-24 parser validates scan and selected bytes for ASCII/control/UTF-8" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var work = try Work.init(allocator, io, 80, 24, 8, 16, null);
    defer work.deinit();
    const corpora = [_][]const u8{
        "ascii row one\r\nascii row two\r\n",
        "\x1b[32mgreen\x1b[0m\tcontrol row\r\n",
        "mixed 汉字 café →\r\nsecond あ row\r\n",
    };
    for (corpora) |corpus| {
        const payload = try makePayload(allocator, corpus);
        defer allocator.free(payload);
        work.payload = payload;
        try work.prepare(.parse_last);
        work.prepareIteration(.parse_last, 0);
        try work.perform(.parse_last, 0);
        try validateParseLast(&work, payload.len);
    }
}

test "incremental headless pipeline feeds every byte and matches one-shot VT" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var work = try Work.init(allocator, io, 80, 24, 8, 16, null);
    defer work.deinit();
    const payload = try makePayload(allocator, "ASCII 汉字 café\x1b[32m green\x1b[0m\r\n");
    defer allocator.free(payload);
    work.payload = payload;
    try work.prepare(.pipeline);
    // No resets between passes: exercise persistent grids and ring wraparound.
    try work.perform(.pipeline, 0);
    try work.perform(.pipeline, 1);
    try std.testing.expectEqual(payload.len, work.pipeline_fed);
    try std.testing.expectEqual(work.ring.head, work.ring.tail);
    try std.testing.expect(work.max_unread <= ring_cap);
    const incremental_hash = hashTerm(&work.term);
    var baseline = try VtState.init(allocator, 80, 24, 1000, work.ring.storage);
    defer baseline.deinit();
    work.loadPayload();
    const runs = work.ring.consumeAndGetRuns(std.math.maxInt(usize));
    baseline.feedRuns(runs);
    baseline.feedRuns(runs);
    try std.testing.expectEqual(hashTerm(&baseline), incremental_hash);
    try std.testing.expectEqualSlices(u32, work.frame.pixels, work.copy_pixels);
}

test "dirty render scenarios actually damage pixels and skip is clean" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var work = try Work.init(allocator, io, 80, 24, 8, 16, null);
    defer work.deinit();
    for ([_]Operation{ .skip, .single, .line, .cursor, .selection, .scroll, .full, .resize }) |op| {
        try work.prepare(op);
        var i: u32 = 0;
        while (i < 2) : (i += 1) {
            work.prepareIteration(op, i);
            try work.perform(op, i);
            try std.testing.expectEqual(op != .skip, work.frame.damaged());
        }
    }
}

# Velocitty implementation specification

## 1. Scope and status

Velocitty is a Linux-only, Omarchy-first terminal emulator. Its executable entry
point is `src/main.zig`; the display and PTY backend is vendored Peak, preferring
Wayland and falling back to X11. Hyprland monitor settings, Omarchy theme files,
and fontconfig are the primary desktop integration points.

This document specifies the **current working-tree implementation**, including
its boundaries and limitations. `DESIGN.md` is the original performance/design
sketch, not proof that all its goals are implemented. Repository source takes
precedence over stale comments, historical tests, benchmark labels, or options
which are parsed but not used. Non-Linux entries left in build metadata/vendor
sources do not establish supported non-Linux products.

The central flow is:

```text
child process <-> Peak PTY
                     |
                     v
              CircBuffer (raw byte ring)
                     |
              LF/ESC scan -> run descriptors
                     |
                     v
                VtState -> Grid[primary, alternate]
                     |       cells / history / cursor / wraps
                     +-----> host effects and PTY replies
                     |
                     v
               Draw.Frame <---- Type.Context / image store / selection
                     |
              CPU pixel buffer -> Peak backbuffer -> present
```

This is an application-managed event loop, not the historical `ZT.Engine` /
libxev architecture. `src/loop.zig` is unused libxev-shaped scaffolding.

## 2. Source structure and ownership

| Area | Sources | Responsibility |
| --- | --- | --- |
| Application | `src/main.zig` | CLI, startup, fonts, layout, reload, event routing, host effects, presentation |
| Platform | `src/platform/platform.zig`, `src/platform/peak.zig`, `vendor/godstack/Peak/` | Zig event/window/PTY wrappers, C ABI bindings, Linux backend |
| Ingestion | `src/circbuffer.zig`, `src/simd.zig` | Mirrored byte ring, timed PTY drain, line/run descriptors, SIMD scans |
| Terminal model | `src/vt.zig`, `src/grid.zig` | Modes, primary/alternate screens, cells, history, cursor, resize, replies |
| Control dispatch | `src/c0.zig`, `src/c1.zig`, `src/esc.zig`, `src/csi.zig`, `src/osc.zig`, `src/dcs.zig` | Selected terminal control families |
| Graphics | `src/kitty.zig`, `src/sixel.zig` | Image transmission/decoding, storage and placements |
| Rendering | `src/draw.zig`, `src/draw/box.zig` | CPU raster composition, dirty work, cursor, selection, box drawing |
| Fonts | `src/type.zig`, `src/type/{truetype,cbdt,atlas,cache,eastasian}.zig` | Font faces/rasterization, color bitmaps, atlases/cache, cell width |
| Input | `src/key.zig`, `src/select.zig` | PTY key encoding and visible-cell selection |
| Configuration/debug | `src/scheme.zig`, `src/debug.zig` | TOML subset/theme loading; Debug-only logs/overlay |
| Build/distribution | `build.zig`, `build.zig.zon`, `scripts/`, desktop/icon/man assets | Build, prefix install, release archives, privileged install |
| Verification | Inline `src/` tests, `tests/`, `src/bench.zig`, `benchmark/` | Current unit checks plus historical harnesses and microbenchmarks |

`main` owns the ring, terminal, font context and font byte blobs, window, frame,
and PTY, with deferred teardown. `VtState` owns grids, dirty/tab bitsets, image
store, replies, and pending host-effect buffers; it **borrows** ring storage.
Run offsets index that storage, so feeding runs is synchronous and must precede
subsequent ring writes. `Type.Context` borrows font bytes: those bytes must
outlive its faces. `Draw.Frame` owns its pixels and retained cell snapshot;
Peak separately owns the destination backbuffer.

## 3. Startup and runtime scheduling

`main` creates an environment-aware `std.Io.Threaded` context, installs reload
signals, loads configuration and monitor data, binds fonts, and initializes an
80x24 terminal. Current startup values are a 64 KiB raw ring, a primary grid
capacity of 1000 total rows, an alternate grid with screen-row capacity,
1024x1024 font atlases, and a 2048-entry glyph cache. These are implementation
choices, not user-configurable contracts.

Each main-loop iteration:

1. Drains Peak events and exits if the window requests closure.
2. Checks config/theme/font stamps, throttled to 250 ms, and handles reload.
3. Applies pending layout changes.
4. Calls `CircBuffer.readPTYPump`, processing window events during PTY waits.
5. Reapplies layout if the pump received focus/resize events.
6. Consumes **all retained lines**, using `consumeAndGetRuns(maxInt(usize))`,
   and feeds runs to the persistent terminal state.
7. Applies pending title, app-id, pointer, clipboard and notification effects,
   updates opacity, and writes terminal replies to the PTY.
8. If `need_draw` is set and synchronized output is not being held, renders,
   clears terminal dirty bits, copies the frame to Peak, and presents.
9. Exits after processing remaining retained output on PTY hangup.

`readPTYPump` reads until EOF/error or until it reaches EAGAIN after the `1/hz`
interval. It waits with positive poll timeouts, not `poll(0)`. The interval is
**not a hard deadline while reads keep succeeding**; sustained input can keep
this drain active. Window pumping happens on the EAGAIN/wait path.

The application chooses `hz` from the focused Hyprland monitor, otherwise 60.
Although config parses `hz`/`refreshrate`, `main` does not apply that value.
DECSET 2026 and iTerm DCS `=1s` hold presentation while state/replies continue
updating. The hold is bounded by `hz` loop iterations, approximately one second
at the intended cadence, not a wall-clock timeout guarantee.

## 4. Raw input, lines and runs

`CircBuffer.create` requires a positive power-of-two capacity. On Linux, a
page-aligned ring uses a memfd mapped twice into adjacent address ranges. If
mapping fails, a double-sized heap buffer is maintained with mirror copies.
This makes retained wraparound input addressable as one contiguous slice.

`head` and `tail` are monotonic byte positions. If unread input exceeds capacity,
`consumeAndPreparse` discards the oldest bytes by advancing `tail`. This is
intentional **lossy firehose handling**: neither arbitrary control state nor
arbitrarily large protocol strings are guaranteed to survive overrun. Raw-byte
retention is distinct from the grid's cell-history retention.

The line scanner uses SIMD helpers to find LF and ESC and records byte ranges
plus an ESC-present bit. It does not execute whitelisted controls or skip
newline-containing escape payloads. The `whitelist` config field is not wired
to this scanner. The run splitter scans the selected lines as a contiguous
range, so embedded LF is not necessarily a runtime parsing failure when all
lines are selected; screen-line-only selection remains a design experiment.

Runs contain `{ kind, off, len }`, borrowing raw storage, and classify C0, C1,
ESC, CSI, OSC, string controls, kitty/sixel-related sequences, printable ASCII,
and UTF-8. **Current plain ASCII spans are 0x21..0x7E**; space is emitted as C0
and prints through `c0.dispatch`. UTF-8 is currently split per sequence, not
coalesced into one run for adjacent codepoints.

On all-lines consumption, the last incomplete ESC/CSI/OSC/string/UTF-8 run is
parked until more bytes arrive. `hold_at_head` prevents repeatedly treating the
unchanged held tail as pending. Holding is limited by ring capacity and is not
an incremental parser for unbounded strings. Line/run arrays retain capacity;
append allocation failures are swallowed, so allocation-free/lossless parsing
is not guaranteed.

Sources: `CircBuffer.{create,readPTYPump,consumeAndPreparse,consumeAndGetRuns,
trimIncomplete,splitIntoRuns}`, `splitIntoLines`, `runIsComplete`.

## 5. Terminal state, grids and control families

`VtState.feedRuns` dispatches descriptors against borrowed storage. Plain bytes
call `printCodepoint` individually; UTF-8 runs use `Utf8View`. Invalid UTF-8
runs are skipped. There is no bulk ASCII `printPlain` fast path in this tree.

Each grid stores packed cells, ring-row offsets, soft-wrap flags, cursor and
saved pen state, scrolling region, history view offset, and delayed-wrap state.
A cell stores a codepoint, attributes, foreground/background RGBA and underline
RGB. Wide codepoints occupy two cells with a zero-codepoint continuation cell.
Hyperlinks are represented by an attribute, not a complete retained link model.

The primary grid retains full-screen scroll history and supports a history
viewport. Typing/pasting returns that view to the bottom. The alternate grid is
for screen-local applications. Column resize reflows primary soft-wrapped
rows; alternate-screen resize clips rather than reflowing TUI content.

Delayed DECAWM wrap leaves the cursor on the last column until the next printed
codepoint. LF/VT/FF index without carriage return; NEL is CR+LF. Cooked shell
newlines normally become CR+LF through the PTY slave's `OPOST|ONLCR`. BEL is
ignored; tab handling writes a tab marker and spaces. Scroll regions and
insert/delete/erase operations update cells and dirty state.

The emulator implements selected operations, not exhaustive xterm/foot/kitty
conformance:

| Family | Implemented responsibilities |
| --- | --- |
| C0/C1 | Index, reverse index, CR, BS, tab and selected shifts/controls |
| ESC | Cursor save/restore, reset, tabs, DEC special character sets, single shifts, alignment |
| CSI | Movement/erase/editing, SGR including truecolor/underline styling, selected DEC modes/reports, rectangles, keyboard negotiation, window geometry and color-stack operations |
| OSC | Title; palette/default/selection colors and alpha; hyperlink flag; cwd; selected notification variants; pointer; clipboard writes; text; shell marks; app-id |
| DCS | Selected DECRQSS and XTGETTCAP replies, iTerm synchronized output, sixel decoding |
| APC kitty | Selected graphics transmission, placement, delete and query operations |

Unknown/unsupported operations are generally ignored or receive only the
implemented handler's response. Replies accumulate in `VtState.reply`; main
flushes them separately from rendering. OSC host requests likewise set pending
state, then `drainHost` performs the platform effect. OSC 9;4 progress, OSC 9;9
cwd, non-`notify;` OSC 777, and kitty OSC 99 close are not notifications.

Unicode handling is cell-width classification plus per-codepoint placement,
not script shaping or full grapheme segmentation. DECSET 2027's current behavior
skips recognized combining marks; with it off, placement clamps width to at
least one. A `ligatures` option does not establish an implemented shaping path.
Full script/grapheme/emoji-sequence behavior from `DESIGN.md` is not provided.

## 6. Fonts, graphics and rendering

`main` resolves regular/bold/italic/bold-italic faces through `fc-match`, with
Noto Color Emoji fallback when available. Fontconfig receives process environ
so user font configuration is honored. Missing fonts allow startup with
placeholder blocks instead of readable font glyphs (`draw.blitLine`).

TrueType outline coverage is rasterized through the stb C wrapper. CBDT/CBLC
supports bitmap color glyphs. `Type.Context` resolves face/style/fallbacks,
prewarms printable ASCII, and uses coverage and RGBA shelf-packed atlases.
Non-ASCII/style glyphs use a fixed-capacity cache keyed by face, glyph, rounded
size and style. The underlying cache has LRU operations, but the glyph hit path
uses `peek`, which **does not refresh recency**. Atlas exhaustion clears caches
and resets packing; it does not reclaim individual glyph rectangles.

`Draw.Frame.renderSel` composites backgrounds, glyphs, decorations, selection,
cursor and stored images into CPU `u32` pixels. It considers terminal row dirty
bits, retained cell snapshots, cursor/style/selection changes, and one-row
scroll shifts. Changed cell spans can reduce fill/blit work. Box drawing has a
procedural renderer; color glyphs use RGBA blits. Control/continuation cells are
not ordinary raster glyphs. Debug builds can paint grid/wrap/cursor/dirty/HUD
overlays requested through OSC/CSI 556; release builds do not expose them.

Dirty rendering and presentation are separate boundaries. The frame exposes
`damaged()`, `dirty_y` and `dirty_h`, but main currently gates on `need_draw` and
uses `blitFrame` to fill/copy the full destination content before presenting.
There is no application-level dirty-band-only presentation contract.

Kitty graphics uses bounded individual transfers/bitmaps (16 MiB), dimensions
up to 4096, and at most 64 images and 64 placements. Supported transports
include direct bytes and file/temporary-file paths. Sixel decodes palette,
repeat and raster attributes to RGBA, with dimensions bounded at 2048 by
default, and places images through the same store. These per-object/count
limits are not a single 16 MiB total application memory budget or a complete
implementation of either graphics protocol.

## 7. Platform and input contracts

Peak supplies window lifecycle, event fd, CPU backbuffer/presentation,
clipboard/PRIMARY, pointer shape/visibility, opacity and PTY spawn/resize.
Wayland uses xdg-shell and optional fractional-scale/viewport, primary-selection,
alpha-modifier and cursor-shape protocols. Integer output scale is a fallback.
Pointer coordinates are converted to backbuffer coordinates. Window geometry
and input regions use logical bounds; pointer leave releases held buttons,
out-of-bounds pointer actions are rejected and extra mouse buttons ignored.
`PEAK_NO_GAMEPAD` disables global joystick polling to preserve compositor
pointer routing. These are guarantees of the vendored implementation, not every
possible compositor/protocol combination.

Wayland text composition uses xkbcommon; X11 uses `XLookupString`, without the
Wayland compose path. Platform events distinguish text from encoded special
keys. `key.encode` chooses legacy/app-cursor/modifyOtherKeys or negotiated kitty
CSI-u behavior. Shift+Tab sends CSI Z in legacy mode, Delete sends CSI 3~, and
keyboard release events currently do not produce PTY key reports.

Mouse reporting supports selected button/motion/wheel modes and SGR/urxvt/pixel
encodings. Without application mouse reporting, wheel scrolls primary history
or sends alternate-screen arrows. Shift bypasses reporting for selection;
left drag selects cells, double-click selects a word and triple-click a line.
Selection uses the visible cell stream, trims trailing blanks and inserts row
newlines; it is not Unicode word segmentation. Focus changes reset click-chain
and held/drag state. Release copies PRIMARY; Ctrl+Shift+C copies CLIPBOARD;
Ctrl+Shift+V/Shift+Insert paste CLIPBOARD; middle-click pastes PRIMARY.
Paste drops NUL, converts LF to CR, and uses bracketed-paste markers if enabled.

The child is `-e`/`--` argv, otherwise `$SHELL` or `/bin/sh`. Spawn temporarily
sets TERM=xterm-256color, COLORTERM=truecolor, TERM_PROGRAM=velocitty,
KITTY_WINDOW_ID, COLUMNS and LINES and clears KITTY_LISTEN_ON, then restores the
parent environment/cwd. Resize updates terminal/frame geometry and PTY winsize
and signals the slave foreground process group. Focus/visibility, theme and
in-band resize reports are emitted only when their modes are enabled.

PTY writes are currently best-effort: `PeakPty.write` retries successful short
writes but returns on would-block/EOF without queuing the remainder;
`flushReply` then clears the reply buffer. Lossless input/replies under PTY
backpressure are therefore not guaranteed. Terminal-output controls can change
clipboard/title/pointer state, request notifications, and use image file
transports under the user's permissions; this boundary is not a sandbox.

## 8. Configuration, scale and distribution

CLI accepts `-e`/`--` command tails and `--class`, `--title`, and
`--working-directory`, with either `=value` or a following value. Defaults are
class `velocitty` and title `Velocitty`; unknown arguments are skipped.

`scheme.load` overlays, in order: XDG user `velocitty/config.toml`, cwd
`config.toml`, Omarchy current theme `colors.toml`, then theme `alacritty.toml`.
Later explicit settings win; inline font tables and fallback font loading fill
only unset family/size values. The parser accepts a TOML subset with
color/font/general settings and ignores unknown keys. Padding defaults to 14.
Unset font family uses fontconfig monospace; size falls back to user Alacritty,
then 9 points when an Omarchy theme path can be constructed, otherwise main's
8-point default. Parsed `whitelist` and `hz` are not active runtime knobs.

Font points are converted using CSS 96 DPI and UI scale, not X11 physical-mm
DPI. Main prefers Hyprland monitor scale, then GDK_SCALE/QT_SCALE_FACTOR, then
1. Focus/resize can refresh scale/layout. SIGUSR1/SIGUSR2 or watched-file changes
reload palette/fonts/metrics, update geometry and invalidate rendering.

`build.zig.zon` declares version 1.0.1 and Zig minimum 0.16.0. Build also needs
Linux libc/toolchain headers and host X11/Wayland headers in `/usr/include`.
Peak is compiled from `vendor/godstack/Peak/peak.c` with `PEAK_NO_GAMEPAD` and
loads desktop libraries dynamically. GNU builds link dl/pthread/util; musl
provides those facilities in libc. stb TrueType/image C sources are linked too.

| Command | Declared build behavior |
| --- | --- |
| `zig build` / `zig build install` | Build selected target/mode, prefix-install binary, desktop entry, icon and manpage |
| `zig build run -- ...` | Depend on prefix install, run executable with forwarded arguments |
| `zig build bench` | Run `src/bench.zig` in ReleaseFast, separately from the desktop executable |
| `zig build release` | ReleaseFast Linux x86_64/aarch64 GNU/musl artifacts |
| `zig build package` | Release plus `packages/velocitty-<version>-<triple>.tar.gz` assets |
| `zig build install-usr` | Host ReleaseFast install to `/usr`, via sudo for TTY or pkexec otherwise |

Declared build behavior is distinct from successful compilation with the
installed compiler. This review does not authorize privileged installs or
publication. Legacy non-Linux target/dependency entries are inactive for the
Linux release filter. The manpage's embedded version is older than the zon
version.

## 9. Benchmark and test inventory

The active build benchmark is `src/bench.zig`, a headless CPU suite with
validated CLI, deterministic workloads and repeated batches. Defaults are five
measured samples, one discarded warmup and ten operations per batch. `--quick`
uses three samples and two operations; explicit counts override those presets.
`--samples`, `--warmup`, `--iterations`, `--font` and `--help` accept the usage
shown by `zig build bench -- --help`; malformed/duplicate arguments fail.

Stages cover synthetic ring copies, explicitly lossy 4 MiB firehose ingestion,
line/run scan and VT feeds for ASCII/control-heavy/mixed-UTF-8 corpora, width
queries, glyph-cache lookups, ASCII atlas reset/prewarm, rasterization and atlas
packing. A retained end-to-end case incrementally ingests 4093-byte chunks,
feeds all runs into persistent VT state, renders and copies an observable CPU
backbuffer. It reports raw/fed/scanned bytes, retained bounds, chunks and loss.
The last-24 paths are marked experiments, not the application's all-lines
semantics; full-scan and selected-feed denominators remain distinct.

Render cases cover full repaint, no change, one cell, one line, cursor,
selection, one-row scroll and column resize at 80x24, 220x60 and approximately
4K pixel dimensions. Larger cases use one operation in quick mode or
`ceil(iterations/5)` normally. State/damage preparation is outside isolated
render timings; resize includes reflow/allocation/render. Width/glyph queries
use ns/query and Mquery/s; frames use ms/frame; actual named input/copy domains
use bytes/op and MiB/s. Damage is a bounding band, not painted-byte bandwidth.

Rows report min/median/nearest-rank p95/max and min-to-max spread of
**batch-average** operation costs. Six decimal places preserve sub-microsecond
no-change frame costs instead of rounding them to zero; displayed precision is
not an accuracy guarantee. These are not individual-frame latency tails or
compositor FPS. Per-operation memory barriers keep writes observable;
checksums and setup/reset are excluded from isolated timings. There is no
misleading startup-cold label: atlas reset explicitly includes ASCII prewarm.
Metadata includes UTC/git status, compiler/target/mode, host CPU, workload and
settings, actual font path/bytes/hash and cell/frame dimensions. Missing fonts
use placeholder rendering and explicitly skip glyph/raster/atlas stages; only
a regular face is loaded, without shaping/fallback-face coverage.

The 18-byte UTC filename formatter is regression-tested. Successful runs write
`bench/<UTC stamp>-<git12>[-dirty].txt` and `last_bench`, both gitignored; save
errors propagate. No real PTY/readPTY, event scheduling, keyboard echo, Peak or
compositor is measured. See §12 for durable current-spec snapshots.

`benchmark/pipeline.zig` is an older ZT-based harness not wired into the current
build. `benchmark/benchmark-pty.sh` measures only kernel PTY throughput, not VT
or rendering. `benchmark/bench.c` is a historical terminal-output stress driver.

Inline tests in current `src/` cover ring holding/mirroring, VT/control/grid
behavior, config, keys/selection, images, font/cache/atlas and Debug rendering.
`tests/vt/` contains text/cell fixtures; `tests/golden/` contains PNG fixtures.
The screenshot/IO/random-render harnesses under `tests/` still import the older
`ZT` API (`Engine`, `Runs`, etc.). Current `build.zig` declares **neither `test`
nor `fuzz-render` steps**, and supplies no `ZT` module. Their presence is not
evidence of an executable regression suite. Golden blessing commands in older
documentation are historical until the harness is migrated/wired.

The two standalone C Peak regressions in `tests/peak_no_gamepad.c` and
`tests/peak_pointer.c` can be compiled directly against vendored Peak, without
opening a compositor window. They test backend internals, not interactive
Wayland/X11 desktop integration. Observed execution and review results belong
in the audit section below; static test counts are not pass counts.

## 10. Design-to-implementation review

| Original goal / older claim | Current implementation |
| --- | --- |
| Mirrored firehose ring | Implemented, with heap-mirror fallback and intentional overrun loss |
| Escape-aware/whitelisted line preparse | LF/ESC scan exists; payload-aware interpretation and config wiring do not |
| Feed only screen-fitting lines | Runtime feeds all retained lines; benchmark compares screen-line alternatives |
| Bulk/vectorized ASCII emulator | SIMD scanning exists; plain VT feed remains per-byte |
| Space/plain and UTF-8 coalescing | Not present in this working tree |
| Full advanced Unicode/shaping | Width tables and per-codepoint glyphs; no full script/grapheme/emoji-sequence shaping |
| Glyph atlas/LRU | Atlases/bounded cache exist; glyph hit peeks do not refresh LRU order |
| Dirty rendering implies dirty present | Rendering has dirty tracking; main copies/presents on `need_draw` |
| Documented Zig golden/fuzz commands | Historical harnesses are disconnected from current build/API |

These gaps are review findings, not changes made by writing this specification.
They should be resolved through separately scoped implementation and regression
work, rather than silently converting design intentions into feature claims.

## 11. Initial audit and follow-up (before benchmark v2)

This section preserves the initial review evidence. Its benchmark source-line
references describe the pre-expansion implementation, not the current file.
The timestamp, units, sampling, warm/cold labeling and optimizer-observability
issues prompted the v2 overhaul described in §9 and verified in §12. Missing
general test/fuzz wiring, nominal ring tests and desktop integration coverage
remain separate follow-up work.

### 11.1 Review scope and execution context

Architecture discovery used separate pipeline and rendering scouts, plus a
runtime/build/configuration review. An independent source review of the drafted
specification found the stale wall-clock sync-timeout claim in `AGENTS.md`;
that wording was corrected. Integration also checked font fallback/placeholder
behavior, configuration precedence and PTY-write boundaries against source.
Benchmark/test review followed the specification review.

Checks ran serially on Linux x86_64 with Zig 0.16.0 and an Intel Core i7-10610U
(8 logical CPUs). Build commands used the existing dirty working tree, not a
clean release baseline. Source/build/test/golden files were not changed by this
work. No privileged install, release publication or interactive desktop test
was performed. Raw logs and diagnostic artifacts are gitignored under
`zig-out/spec-review/`; findings needed for follow-up are retained here.

### 11.2 Observed command results

| Check | Observed result |
| --- | --- |
| `zig build -Doptimize=ReleaseFast` | Exit 0; host build and local prefix install succeeded |
| `zig build test` | Exit 1: no step named `test` |
| `zig build fuzz-render -- 10000` | Exit 1: no step named `fuzz-render` |
| `zig build bench` | Binary compiled and started, then stalled inside `utcStamp` before stage measurements; initial run terminated after a 240-second command timeout |
| `timeout 10s zig build bench`, with disk-backed TMPDIR | Exit 124 at the same timestamp-preparation point; no throughput/frame measurements |
| Both standalone Peak C regressions | Initial compile failed with `/tmp` disk-quota errors; retries using project-local TMPDIR compiled and ran, exit 0 for both |
| `zig test zig-out/spec-review/bench-stamp-check.zig` | Exit 0; isolated format check confirms the 16-byte buffer fails and the 18-byte buffer succeeds |
| `git diff --check` | Passed at integration |

Successful direct inline suites used these commands (counts are Zig-reported
OK results, **not additive**, since imported modules overlap):

| Command | Reported OK |
| --- | ---: |
| `zig test src/main.zig src/type/stb_truetype.c src/stb_image.c -Ilib -lc` | 75 |
| `zig test src/vt.zig src/stb_image.c -Ilib -lc` | 54 |
| `zig test src/type.zig src/type/stb_truetype.c src/stb_image.c -Ilib -lc` | 17 |
| `zig test src/scheme.zig` | 11 |
| `zig test src/key.zig` | 7 |
| `zig test src/circbuffer.zig` | 5 |
| `zig test src/grid.zig` | 1 |
| `zig test src/type/cache.zig` | 4 |
| `zig test src/type/atlas.zig` | 2 |
| `zig test src/type/eastasian.zig` | 3 |

All commands in this inline table exited 0; no assertion failures were observed.
Earlier VT/type attempts without the necessary image/TrueType C wrappers failed
at linking, not at assertions. The main-root suite additionally exercised the
focus/click-chain, selection, box-drawing and Debug-overlay tests. It does not
launch a window or prove compositor integration.

The successful C follow-up commands were:

```sh
mkdir -p zig-out/spec-review/local-tmp
export TMPDIR="$PWD/zig-out/spec-review/local-tmp"
cc -Ivendor/godstack/Peak tests/peak_no_gamepad.c \
  -o zig-out/spec-review/peak-no-gamepad -ldl -lpthread -lm
zig-out/spec-review/peak-no-gamepad
cc -Ivendor/godstack/Peak tests/peak_pointer.c \
  -o zig-out/spec-review/peak-pointer -ldl -lpthread -lm
zig-out/spec-review/peak-pointer
```

### 11.3 Benchmark blocker and measurement review

**Confirmed blocker:** `Stamp.file` and the local filename buffer are `[16]u8`
(`src/bench.zig:849,870`), but their format produces 18 bytes:
`YYYY-MM-DDTHHMMSSZ` (`:879–886`). An isolated check of that exact format returns
`error.NoSpaceLeft` for 16 bytes and succeeds for 18. The production formatter
uses `catch unreachable` for that reachable error, which is undefined behavior
in ReleaseFast. `saveLog` also declares a 16-byte stamp (`:926`). Both observed
benchmark runs stopped after the timestamp diagnostic, before `bench: stamp`,
`bench: git`, or any pipeline timing. Fix this boundary/error handling before
attempting performance conclusions. No benchmark numbers or regressions were
measured in this review.

The remaining measurement issues are source-review findings, not measured
performance defects:

- **Domain/denominators:** firehose ingest intentionally discards old data;
  it is not lossless terminal throughput. Last-24 paths differ from runtime's
  all-lines feed. Combined last-24 timing includes full-ring line scanning but
  its MiB/s numerator counts only selected run bytes (`:170–231`). Width-query,
  glyph-coverage and nominal framebuffer-byte rows use different work units;
  their MiB/s values should not be compared as one common bandwidth measure.
- **Cold versus warm:** `benchDraw` calls `clearAtlas` before its cold timer
  (`:356–365`), and `clearAtlas` prewarms ASCII (`src/type.zig:227–230`). That
  label is not startup-cold font/rasterization cost.
- **Optimizer observability:** `benchPresentCopy` repeats identical copies to
  an unread temporary (`src/bench.zig:611–622`); the memset loop likewise repeats
  the same zeroing (`:450–455`). No explicit observation/barrier guarantees that
  every repetition survives optimization. Generated-code inspection or an
  observable checksum/barrier is needed before treating these as copy costs.
- **Presentation/latency:** synthetic memcpy and hot/no-change render rows omit
  Peak/compositor present, event scheduling, PTY backpressure and input-to-echo
  latency. Nominal framebuffer MiB/s on a skip frame is not painted-byte
  throughput or an achieved display refresh rate.
- **Reproducibility:** fixed loop counts and UTC/git stamps do not supply
  repeated-run variance, consistent machine load or a comparable baseline.
  Font paths are hardcoded; actual font, cell/frame dimensions, CPU/compiler
  and optimization must accompany future measurements. No old-tree comparison
  was available. The only readable benchmark fallback path in this environment
  was Liberation Mono; rendering never reached its font-loading stage.

The historical ZT pipeline harness, the C stdout stress driver and the 10 GiB
kernel-PTY shell benchmark were reviewed statically, not executed. They cannot
substitute for a working current application benchmark.

### 11.4 Test-quality findings and prioritized follow-up

1. **High: restore the validation entry points.** Add current-model `test` /
   `fuzz-render` wiring and migrate the removed ZT API harness before claiming
   screenshot, golden, random-render or historical firehose coverage. Native
   inline tests are useful but do not replace those disconnected suites.
2. **High: repair the benchmark timestamp boundary.** Correct all stamp-size
   interfaces and replace the reachable `unreachable` assumption; add a date
   formatting regression check, then collect bounded comparable runs.
3. **Medium: replace nominal ring tests with real assertions.**
   `src/circbuffer.zig:590` is empty. The hardware-mirroring test (`:592–612`)
   returns on the mapped path and has no alias/wrap assertions on either path.
   Thus two of its five reported OK results do not validate their names.
   Add mapping and heap-fallback wrap/overrun checks and byte-boundary tests for
   UTF-8, ESC/CSI/OSC/string terminators and newline-containing payloads.
4. **Medium: extend rendering and runtime scenarios.** The legacy random
   comparison uses a 20x8 grid, 4x4 cells, no font context and a disabled cursor
   (`tests/vt_rand.zig:4–32`). Even after migration it needs explicit glyph,
   cursor, selection, image, resize/reflow and theme/scale cases. Add targeted
   scheduling/sync and PTY backpressure checks rather than inferring them from
   cell-model tests. Real Wayland/X11 focus, scale, clipboard and hit routing
   remain manual/integration checks.
5. **Medium: make font dependencies observable.** Tests in `src/type.zig` and
   `src/type/cbdt.zig` return normally on font open/read errors, so Zig reports
   OK rather than an explicit skip. A final filesystem check found Liberation
   Mono, Noto Color Emoji and all three hardcoded Iosevka style paths readable;
   this review therefore does **not** claim those tests were skipped here.
   Nevertheless, their OK summaries alone cannot distinguish an exercised
   assertion from a silent early return. Use deterministic assets or explicit
   skips for portable verification.
6. **Medium: tighten benchmark semantics.** Separate byte-throughput from
   query/frame metrics, fix cold/warm labeling, preserve observable work, and
   add realistic dirty-frame/end-to-end cases plus repeated-run summaries.

These were recommendations from the initial audit. That phase wrote only
documentation and ignored verification artifacts; `README.md`, existing user
changes and golden fixtures were preserved. The separately requested benchmark
implementation is recorded below.

## 12. Expanded benchmark verification and recurring snapshots

### 12.1 Implementation and scope

The benchmark overhaul is confined to `src/bench.zig`; emulator, renderer,
platform, font and general build/test behavior were not changed. It fixes the
UTC buffer defect, replaces misleading units/cold labels, adds sampling and
observable work, and expands the workloads/damage cases described in §9.

Regression checks cover epoch/leap-day/midnight stamp formatting, CLI bounds
and quick/default precedence, median/nearest-rank statistics, distinct scanned
versus selected byte validation, incremental-feed equivalence with one-shot
VT, ring wrap across repeated passes, and expected render damage versus skips.
Last-24 validation compares the full scanned line total with the scan-domain
units and selected run bytes with the selected line total—not with all input.

Remaining limits are explicit: ingestion is synthetic memory IO, not an actual
PTY/readPTY benchmark; there is no keyboard echo, event-loop, Peak or compositor
latency measurement. A regular font face is used; missing codepoints may use
replacement glyphs. Tail summaries are tails of batch averages, not individual
frame events. Source fingerprints do not make CPU load/power policy, fonts,
compiler or the rest of the environment hermetic.

### 12.2 Observed verification

- `zig fmt --check src/bench.zig` and `git diff --check` passed.
- Before the final extra last-24 regression, the direct imported suite reported
  all 84 tests OK. The final complete suite reported 84/85 OK: the existing
  `kitty.test.file transmit places png` failed writing its hardcoded `/tmp`
  fixture with `DQUOT`. Project-local TMPDIR fixes compiler scratch, but cannot
  redirect that test's literal path. No unrelated test/source was changed to
  hide this environment failure.
- `zig test src/bench.zig src/type/stb_truetype.c src/stb_image.c -Ilib -lc
  --test-filter bench.test` then reported all seven selected tests OK: six
  benchmark regressions and one import-only type marker.
- The final `zig build bench -- --quick` completed with all stage checks and
  saved logs. A full-default run also completed during implementation with
  five samples, one warmup and ten operations; it is not a regression baseline.
- The host `zig build -Doptimize=ReleaseFast` passed.
- `bash -n scripts/bench-spec.sh` and disposable fake-Zig Git fixture checks
  passed. Scenarios covered outside-repository invocation, exact forwarded
  argument boundaries, help/incomplete-run rejection, quick/custom labeling,
  capture/hash failures, source/SPEC/HEAD mutations, source manifest digests,
  clean/dirty/mismatched gitlinks and preservation of unrelated staged files
  during snapshot-only commits. Fixture commits were not project commits.

Raw integration logs remain under ignored
`zig-out/spec-review/expanded-verify/`. Durable full measurement reports live
in `benchmarks/` with their exact spec and checked source identities, rather
than being folded into this specification's prose as timeless performance
claims. Compare their row statistics and conditions, not a single headline
throughput or an inferred compositor FPS.

### 12.3 Snapshot helper

```sh
scripts/bench-spec.sh                          # full defaults; archive for review
scripts/bench-spec.sh --commit                 # full defaults; commit archive only
scripts/bench-spec.sh -- --quick                # labeled quick archive
scripts/bench-spec.sh --commit -- --samples 9 --warmup 2 --iterations 20
scripts/bench-spec.sh --help
```

`--` separates helper options from benchmark arguments; the helper inserts
Zig's own argument separator. It runs from the repository root even when
invoked elsewhere, so custom relative font paths are relative to that root.
It chooses disk-backed `zig-out/bench-spec-tmp` when TMPDIR is unset and uses
`flock` when available to exclude concurrent helper runs.

Each successful archive is published at
`benchmarks/<UTC-nanoseconds>-<head12>/` and contains:

| File | Content |
| --- | --- |
| `report.txt` | Complete direct benchmark stdout/stderr, including settings, environment, all row statistics, checksums and completion marker |
| `SPEC.md` | Exact pre-run specification bytes |
| `source-manifest.txt` | Per-file hashes for checked source/build/lib/vendor/script/spec/design/agent inputs, with deletions and gitlink identities represented |
| `metadata.txt` | UTC run id, measured pre-run HEAD/dirty state, spec SHA-256, manifest fingerprint, default/quick/custom classification and shell-escaped command |

Tracked and nonignored untracked inputs in those domains are checked before
and after measurement. The helper refuses changed HEAD/spec/source manifests,
failed benchmark or output capture, absent completion markers, and unsupported
dirty/mismatched relevant submodules. Publication uses an atomic rename on the
same filesystem; failed preparations never become successful archives.

`--commit` stages and commits **only the newly published archive**, preserving
unrelated staged work and leaving code/spec edits for their own deliberate
commits. Normal ignored `bench/` and `last_bench` outputs remain convenience
logs, not the authoritative spec-associated archive. A report produced from a
dirty tree records that fact; its manifest identifies measured bytes instead
of falsely attributing uncommitted inputs to HEAD.

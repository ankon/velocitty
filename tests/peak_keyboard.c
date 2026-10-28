/* Test actual Wayland callback, queue, and public Peak event API without a compositor. */
#define PEAK_NO_GAMEPAD
#include "../vendor/godstack/Peak/peak.c"
static struct peak_wayland_win test_window;
static unsigned char test_char;
static uint32_t test_sym(struct xkb_state *s, uint32_t kc) {
    (void)s;
    return kc == KEY_LEFTBRACE + 8 ? XK_bracketleft : XK_a;
}
static int test_utf8(struct xkb_state *s, uint32_t kc, char *buf, size_t cap) {
    (void)s; (void)kc; (void)cap;
    buf[0] = (char)test_char;
    if (test_char == 0xc3) { buf[1] = (char)0xa9; buf[2] = 0; return 2; }
    buf[1] = 0; return 1;
}

/* Real libxkbcommon keymap, actual Wayland callbacks and event queue. */
int test_keyboard_swapescape(void) {
    struct test_rule_names {
        const char *rules, *model, *layout, *variant, *options;
    } names = { NULL, NULL, "us", NULL, "caps:swapescape" };
    struct xkb_keymap *(*from_names)(struct xkb_context *, const struct test_rule_names *, int);
    struct xkb_context *ctx;
    struct xkb_keymap *km = NULL;
    struct xkb_state *st = NULL;
    PeakEvent ev;
    int result = 0;
    unsigned int i;
    const uint32_t mods[] = { 0, 1, 4, 8 }; /* none, Shift, Control, Alt */
    /* The other test installs a sentinel state; never unref that. */
    peak_wayland.xkb_state = NULL;
    peak_wayland.xkb_keymap = NULL;
    peak_wayland.timer_fd = -1;
    if (!peak_wayland_xkb_load()) return -1;
    /* Reload in case the synthetic test ran first. */
    peak_xkb.xkb_state_key_get_one_sym = dlsym(peak_xkb.handle, "xkb_state_key_get_one_sym");
    peak_xkb.xkb_state_key_get_utf8 = dlsym(peak_xkb.handle, "xkb_state_key_get_utf8");
    from_names = dlsym(peak_xkb.handle, "xkb_keymap_new_from_names");
    if (!from_names) return -1;
    ctx = peak_xkb.xkb_context_new(0);
    if (!ctx) return -1;
#define CHECK_SWAP(cond) do { if (!(cond)) { result = __LINE__; goto done; } } while (0)
    km = from_names(ctx, &names, 0);
    CHECK_SWAP(km);
    st = peak_xkb.xkb_state_new(km);
    CHECK_SWAP(st);
    peak_wayland.xkb_keymap = km;
    peak_wayland.xkb_state = st;
    memset(&test_window, 0, sizeof test_window);
    peak_wayland.focus = &test_window;
    peak_wayland.timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    peak_wayland.repeat_rate = 25;
    peak_wayland.repeat_delay = 600;
    CHECK_SWAP(peak_wayland.timer_fd >= 0);
    for (i = 0; i < sizeof mods / sizeof mods[0]; ++i) {
        peak_wayland_keyboard_mod(NULL, NULL, 0, mods[i], 0, 0, 0);
        peak_wayland_keyboard_key(NULL, NULL, 0, 0, KEY_CAPSLOCK, 1);
        CHECK_SWAP(peak_q_pop(&test_window.q, &ev));
        CHECK_SWAP(ev.type == PEAK_EVENT_KEY_DOWN && ev.key.key == PEAK_KEY_ESCAPE);
        CHECK_SWAP(ev.key.code == 27);
        CHECK_SWAP(!peak_q_pop(&test_window.q, &ev));
        CHECK_SWAP(peak_wayland.repeat_key == KEY_CAPSLOCK);
        peak_wayland_keyboard_key(NULL, NULL, 0, 0, KEY_CAPSLOCK, 0);
        CHECK_SWAP(peak_q_pop(&test_window.q, &ev));
        CHECK_SWAP(ev.type == PEAK_EVENT_KEY_UP && ev.key.key == PEAK_KEY_ESCAPE);
        CHECK_SWAP(peak_wayland.repeat_key == 0);
        peak_wayland_keyboard_key(NULL, NULL, 0, 0, KEY_ESC, 1);
        CHECK_SWAP(peak_q_pop(&test_window.q, &ev));
        CHECK_SWAP(ev.type == PEAK_EVENT_KEY_DOWN && ev.key.key == PEAK_KEY_UNKNOWN && ev.key.code == 0);
        CHECK_SWAP(!peak_q_pop(&test_window.q, &ev));
        CHECK_SWAP(peak_wayland.repeat_key == 0);
        peak_wayland_keyboard_key(NULL, NULL, 0, 0, KEY_ESC, 0);
        CHECK_SWAP(peak_q_pop(&test_window.q, &ev));
        CHECK_SWAP(ev.type == PEAK_EVENT_KEY_UP && ev.key.key == PEAK_KEY_UNKNOWN);
        CHECK_SWAP(!peak_q_pop(&test_window.q, &ev));
    }
done:
    if (peak_wayland.timer_fd >= 0) close(peak_wayland.timer_fd);
    peak_wayland.timer_fd = -1;
    peak_wayland.repeat_key = 0;
    peak_wayland.focus = NULL;
    peak_wayland.xkb_state = NULL;
    peak_wayland.xkb_keymap = NULL;
    peak_wayland.mod = 0;
    if (st) peak_xkb.xkb_state_unref(st);
    if (km) peak_xkb.xkb_keymap_unref(km);
    peak_xkb.xkb_context_unref(ctx);
#undef CHECK_SWAP
    return result;
}

void test_keyboard_setup(PeakWindow *win, int scenario) {
    memset(&test_window, 0, sizeof test_window);
    memset(win, 0, sizeof *win);
    win->internal.w = &test_window;
    peak_linux_kind = PEAK_LINUX_WAYLAND;
    peak_wayland.xkb_state = NULL;
    peak_wayland.xkb_keymap = NULL;
    peak_xkb.xkb_state_key_get_one_sym = test_sym;
    peak_wayland.mod = 0;
    if (scenario == 0) {
        peak_wayland_key_emit(&test_window, KEY_A, 1, 0);
        peak_wayland_key_emit(&test_window, KEY_B, 1, 0);
    } else if (scenario == 1) {
        peak_wayland.mod = PEAK_KEYMOD_ALT;
        peak_wayland_key_emit(&test_window, KEY_A, 1, 0);
    } else if (scenario >= 5) {
        peak_wayland.mod = scenario == 6 ? PEAK_KEYMOD_ALT : 0;
        peak_wayland.xkb_state = (struct xkb_state *)1;
        peak_xkb.xkb_state_key_get_utf8 = test_utf8;
        test_char = 0xc3;
        peak_wayland_key_emit(&test_window, KEY_A, 1, 0);
    } else {
        peak_wayland.mod = PEAK_KEYMOD_CTRL;
        peak_wayland.xkb_state = (struct xkb_state *)1;
        peak_xkb.xkb_state_key_get_utf8 = test_utf8;
        test_char = (unsigned char)(scenario + 25); /* 27, 28, 29 */
        peak_wayland_key_emit(&test_window, KEY_LEFTBRACE, 1, 0);
    }
}

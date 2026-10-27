/* Test actual Wayland callback, queue, and public Peak event API without a compositor. */
#define PEAK_NO_GAMEPAD
#include "../vendor/godstack/Peak/peak.c"
static struct peak_wayland_win test_window;
static unsigned char test_char;
static int test_utf8(struct xkb_state *s, uint32_t kc, char *buf, size_t cap) {
    (void)s; (void)kc; (void)cap;
    buf[0] = (char)test_char;
    if (test_char == 0xc3) { buf[1] = (char)0xa9; buf[2] = 0; return 2; }
    buf[1] = 0; return 1;
}
void test_keyboard_setup(PeakWindow *win, int scenario) {
    memset(&test_window, 0, sizeof test_window);
    memset(win, 0, sizeof *win);
    win->internal.w = &test_window;
    peak_linux_kind = PEAK_LINUX_WAYLAND;
    peak_wayland.xkb_state = NULL;
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

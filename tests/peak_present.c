/* Headless regression tests for Peak's Wayland partial present.
 * cc -Ivendor/godstack/Peak tests/peak_present.c -o /tmp/peak-present -ldl -lpthread -lm
 */
#include "../vendor/godstack/Peak/peak.c"
#include <assert.h>

#define SURF ((struct wl_proxy *)9)

static int damage_full, damage_buffer, commits;
static int32_t dmg[4];
static uint32_t surface_version = 4;

static struct wl_proxy *marshal(struct wl_proxy *p, uint32_t op,
    const struct wl_interface *iface, uint32_t version, uint32_t flags,
    union wl_argument *a)
{
    (void)iface; (void)version; (void)flags;
    if (p == SURF && op == 2) damage_full++;
    if (p == SURF && op == 9) {
        damage_buffer++;
        memcpy(dmg, (int32_t[4]){ a[0].i, a[1].i, a[2].i, a[3].i }, sizeof dmg);
    }
    if (p == SURF && op == 6) commits++;
    return (struct wl_proxy *)2;
}
static uint32_t version(struct wl_proxy *p) { return p == SURF ? surface_version : 1; }
static void destroy(struct wl_proxy *p) { (void)p; }
static int flush(struct wl_display *d) { (void)d; return 0; }

static void reset(void) { damage_full = damage_buffer = commits = 0; }

int main(void)
{
    enum { W = 4, H = 6 };
    uint32_t buffer[W * H], shm[W * H];
    struct peak_wayland_win w = {0};
    PeakWindowInternal intern = {0};
    size_t i;

    peak_wl.wl_proxy_marshal_array_flags = marshal;
    peak_wl.wl_proxy_get_version = version;
    peak_wl.wl_proxy_destroy = destroy;
    peak_wl.wl_display_flush = flush;
    wl_region_interface.name = "wl_region";
    w.width = W; w.height = H; w.logical_w = W; w.logical_h = H;
    w.surface = (struct wl_surface *)SURF;
    w.wl_buf = (struct wl_buffer *)5;
    w.buffer = buffer; w.shm = shm; w.shm_n = sizeof shm;
    w.opacity = 255;
    w.shm_stale = 1;
    intern.w = &w;

    for (i = 0; i < W * H; i++) buffer[i] = 0xff000000u | (uint32_t)i;
    memset(shm, 0, sizeof shm);

    /* A stale shm (new buffer) always presents everything. */
    peak_wayland_window_present_rect(&intern, 2, 1);
    assert(damage_full == 1 && damage_buffer == 0 && commits == 1);
    assert(!memcmp(shm, buffer, sizeof shm));

    /* Then only the requested rows are copied and damaged in buffer pixels. */
    reset();
    for (i = 0; i < W * H; i++) buffer[i] = 0xff00ff00u;
    peak_wayland_window_present_rect(&intern, 2, 2);
    assert(damage_full == 0 && damage_buffer == 1 && commits == 1);
    assert(dmg[0] == 0 && dmg[1] == 2 && dmg[2] == W && dmg[3] == 2);
    for (i = 0; i < W * H; i++) {
        int row = (int)(i / W);
        assert((shm[i] == 0xff00ff00u) == (row == 2 || row == 3));
    }

    /* Nothing damaged: no commit. Rows past the end are clipped. */
    reset();
    peak_wayland_window_present_rect(&intern, 0, 0);
    assert(commits == 0);
    peak_wayland_window_present_rect(&intern, 5, 9);
    assert(damage_buffer == 1 && dmg[1] == 5 && dmg[3] == 1);

    /* Opacity change and wl_surface < 4 fall back to full damage. */
    reset();
    w.shm_stale = 1;
    peak_wayland_window_present_rect(&intern, 1, 1);
    assert(damage_full == 1 && !memcmp(shm, buffer, sizeof shm));
    reset();
    surface_version = 3;
    peak_wayland_window_present_rect(&intern, 1, 1);
    assert(damage_full == 1 && damage_buffer == 0);

    /* Full present is unchanged: whole surface. */
    reset();
    surface_version = 4;
    peak_wayland_window_present(&intern);
    assert(damage_full == 1 && damage_buffer == 0 && commits == 1);

    puts("Peak Wayland present tests passed");
    return 0;
}

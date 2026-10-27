#define PEAK_NO_GAMEPAD
#include "../vendor/godstack/Peak/peak.c"
#include <pty.h>
#include <termios.h>
#include <unistd.h>

static int slave_fd;
int queue_test_open(void) {
    int master;
    struct termios term;
    if (openpty(&master, &slave_fd, NULL, NULL, NULL) < 0) return -1;
    if (tcgetattr(slave_fd, &term) < 0) return -1;
    term.c_lflag = 0; term.c_iflag = 0; term.c_oflag = 0; term.c_cflag |= CS8;
    term.c_cc[VMIN] = 1; term.c_cc[VTIME] = 0;
    if (tcsetattr(slave_fd, TCSANOW, &term) < 0) return -1;
    peak_internal_nb(master);
    peak_internal_nb(slave_fd);
    return master;
}
int queue_test_read(char *dst, size_t len) {
    ssize_t n = read(slave_fd, dst, len);
    return n > 0 ? (int)n : 0;
}
void queue_test_close(void) { close(slave_fd); }

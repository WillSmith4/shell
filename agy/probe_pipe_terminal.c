/* Probe the existing TUI on pipes, as supplied by a-Shell, without a PTY. */
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int enabled;
static struct winsize size;
static struct termios mode;

void agy_probe_pipe_terminal(int active, unsigned short columns, unsigned short rows) {
    pthread_mutex_lock(&lock);
    enabled = active;
    if (active) {
        memset(&mode, 0, sizeof(mode));
        mode.c_iflag = ICRNL;
        mode.c_oflag = OPOST | ONLCR;
        mode.c_cflag = CREAD | CS8;
        mode.c_lflag = ICANON | ECHO | ISIG;
        mode.c_cc[VMIN] = 1;
        size.ws_col = columns;
        size.ws_row = rows;
    }
    pthread_mutex_unlock(&lock);
}

int ioctl(int fd, unsigned long request, ...) {
    void *argument = NULL;
    if (!(request & IOC_VOID)) {
        va_list args;
        va_start(args, request);
        argument = va_arg(args, void *);
        va_end(args);
    }
    pthread_mutex_lock(&lock);
    if (enabled && (fd == 0 || fd == 1)) {
        if (request == TIOCGETA) {
            *(struct termios *)argument = mode;
        } else if (request == TIOCSETA || request == TIOCSETAW || request == TIOCSETAF) {
            mode = *(struct termios *)argument;
        } else if (request == TIOCGWINSZ) {
            *(struct winsize *)argument = size;
        } else {
            pthread_mutex_unlock(&lock);
            goto system_ioctl;
        }
        pthread_mutex_unlock(&lock);
        return 0;
    }
    pthread_mutex_unlock(&lock);
system_ioctl:;
    int (*real_ioctl)(int, unsigned long, ...) = dlsym(RTLD_NEXT, "ioctl");
    if (!real_ioctl) { errno = ENOSYS; return -1; }
    if (request & IOC_VOID) return real_ioctl(fd, request);
    return real_ioctl(fd, request, argument);
}

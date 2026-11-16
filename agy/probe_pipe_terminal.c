/* Probe the existing TUI on pipes, as supplied by a-Shell, without a PTY. */
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int enabled;
static struct winsize size;
static struct termios mode;
static struct stat streams[2];
static int captured[2];

static int system_fstat(int fd, struct stat *metadata) {
    int (*real_fstat)(int, struct stat *) = dlsym(RTLD_NEXT, "fstat");
    if (!real_fstat) { errno = ENOSYS; return -1; }
    return real_fstat(fd, metadata);
}

void agy_session_terminal(int active, int input, int output, unsigned short columns, unsigned short rows) {
    pthread_mutex_lock(&lock);
    enabled = active;
    if (active) {
        captured[0] = system_fstat(input, &streams[0]) == 0;
        captured[1] = system_fstat(output, &streams[1]) == 0;
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

void agy_probe_pipe_terminal(int active, unsigned short columns, unsigned short rows) {
    agy_session_terminal(active, 0, 1, columns, rows);
}

static int matches_terminal(const struct stat *candidate) {
    for (int i = 0; i < 2; ++i)
        if (captured[i] && candidate->st_dev == streams[i].st_dev &&
            candidate->st_ino == streams[i].st_ino &&
            (candidate->st_mode & S_IFMT) == (streams[i].st_mode & S_IFMT)) return 1;
    return 0;
}

static int terminal_alias(int fd) {
    struct stat candidate;
    return system_fstat(fd, &candidate) == 0 && matches_terminal(&candidate);
}

int fstat(int fd, struct stat *metadata) {
    int result = system_fstat(fd, metadata);
    if (result) return result;
    pthread_mutex_lock(&lock);
    // main.readStdinPrompt checks ModeCharDevice, not isatty, before deciding
    // whether to consume stdin to EOF as a noninteractive prompt. Only the
    // captured interactive streams have terminal identity inside this engine.
    if (enabled && matches_terminal(metadata))
        metadata->st_mode = (metadata->st_mode & ~S_IFMT) | S_IFCHR;
    pthread_mutex_unlock(&lock);
    return 0;
}

int isatty(int fd) {
    pthread_mutex_lock(&lock);
    int result = enabled && terminal_alias(fd);
    pthread_mutex_unlock(&lock);
    if (result) return 1;
    int (*real_isatty)(int) = dlsym(RTLD_NEXT, "isatty");
    if (!real_isatty) { errno = ENOSYS; return 0; }
    return real_isatty(fd);
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
    // termio.Redirect keeps duplicated copies of the original streams before
    // redirecting process stdout/stderr to the engine log. Follow those copies.
    if (enabled && terminal_alias(fd)) {
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

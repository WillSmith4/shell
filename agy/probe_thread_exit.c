/* Link only the probe engine against this library. Keep the host on libSystem. */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern void ios_exit(int status) __attribute__((noreturn));

static void finish_command(int status) __attribute__((noreturn));
static void finish_command(int status) {
    fprintf(stderr, "agy calls ios_exit(%d), on main thread: %d\n",
            status, pthread_main_np());
    fflush(stderr);
    ios_exit(status);
}

void exit(int status) {
    finish_command(status);
}

void _exit(int status) {
    finish_command(status);
}

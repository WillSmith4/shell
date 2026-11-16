/* Link only the probe engine against this library. Keep the host on libSystem. */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern void ios_exit(int status) __attribute__((noreturn));

// Go may redirect stderr before exiting. Retain the original diagnostic stream
// in the isolated test host so the exit and command thread IDs can be compared.
static int diagnostics = -1;
__attribute__((constructor)) static void retain_diagnostics(void) {
    diagnostics = dup(STDERR_FILENO);
}

static void finish_command(int status) __attribute__((noreturn));
static void finish_command(int status) {
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    dprintf(diagnostics, "agy calls ios_exit(%d), on main thread: %d, exit thread %llu\n",
            status, pthread_main_np(), (unsigned long long)tid);
    ios_exit(status);
}

void exit(int status) {
    finish_command(status);
}

void _exit(int status) {
    finish_command(status);
}

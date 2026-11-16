/* Lifecycle rendezvous for the isolated original-TUI experiment. */
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <time.h>
#include <dlfcn.h>

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static unsigned completed, resumed;
static int failed;

void agy_engine_ended(void) {
    pthread_mutex_lock(&mutex);
    failed = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
}

int agy_probe_wait_ui(unsigned invocation, unsigned seconds) {
    struct timespec until;
    if (clock_gettime(CLOCK_REALTIME, &until)) return errno;
    until.tv_sec += seconds;
    pthread_mutex_lock(&mutex);
    int result = 0;
    while (!failed && completed < invocation && !result)
        result = seconds ? pthread_cond_timedwait(&changed, &mutex, &until)
                         : pthread_cond_wait(&changed, &mutex);
    if (failed) result = EPIPE;
    pthread_mutex_unlock(&mutex);
    return result;
}

int agy_probe_resume_ui(void) {
    pthread_mutex_lock(&mutex);
    int result = EBUSY;
    if (completed == resumed + 1) {
        resumed = completed;
        pthread_cond_broadcast(&changed);
        result = 0;
    }
    pthread_mutex_unlock(&mutex);
    return result;
}

int kill(pid_t pid, int signal) {
    // The pinned main.main patch calls the existing Go syscall.Kill wrapper at
    // the former chanrecv call site. This preserves a Go syscall transition and
    // the existing main stack frame. The reserved request never reaches the OS.
    // All ordinary calls retain their original libSystem implementation.
    if (pid != INT_MIN || signal != 0) {
        int (*real_kill)(pid_t, int) = dlsym(RTLD_NEXT, "kill");
        if (!real_kill) { errno = ENOSYS; return -1; }
        return real_kill(pid, signal);
    }
    pthread_mutex_lock(&mutex);
    ++completed;
    pthread_cond_broadcast(&changed);
    while (resumed < completed) pthread_cond_wait(&changed, &mutex);
    pthread_mutex_unlock(&mutex);
    return 0;
}

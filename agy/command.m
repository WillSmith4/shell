#import <Foundation/Foundation.h>
#include "ios_system.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

extern int ios_getWindowSize(int *, int *, const void *);
extern int ios_opentty(void);
extern void ios_closetty(void);
static int (*resumeUI)(void);
static int (*waitUI)(unsigned, unsigned);
static void (*engineEnded)(void);
static void (*sessionTerminal)(int, int, int, unsigned short, unsigned short);

enum { Input = 96, EngineOut, EngineErr, UIOut, UIErr };
static pthread_mutex_t commandLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned invocation;
static int nullFD = -1;
static void (*entry)(int, char **);
static char **startup;

static NSString *enginePath(void) {
    Dl_info info;
    if (!dladdr((void *)&enginePath, &info)) return nil;
    NSString *frameworks = [[NSString stringWithUTF8String:info.dli_fname]
        stringByDeletingLastPathComponent].stringByDeletingLastPathComponent;
    return [frameworks stringByAppendingPathComponent:@"AgyEngine.framework/AgyEngine"];
}

static int reserveStreams(void) {
    if (nullFD >= 0) return 0;
    nullFD = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (nullFD < 0) return errno;
    for (int fd = Input; fd <= UIErr; ++fd) {
        int got = fcntl(nullFD, F_DUPFD_CLOEXEC, fd);
        if (got != fd) {
            int error = got < 0 ? errno : EBUSY;
            if (got >= 0) close(got);
            for (int owned = Input; owned < fd; ++owned) close(owned);
            close(nullFD);
            nullFD = -1;
            return error;
        }
    }
    return 0;
}

static int prepareEngine(NSString *path) {
    if (entry) return 0;
    if (!path) return ENOENT;
    void *image = dlopen(path.fileSystemRepresentation, RTLD_LOCAL | RTLD_NOW);
    if (!image) { fprintf(thread_stderr, "agy: %s\n", dlerror()); return ENOEXEC; }
    void (*start)(int, char **) = dlsym(image, "agy_probe_process_entry");
    resumeUI = dlsym(image, "agy_probe_resume_ui");
    waitUI = dlsym(image, "agy_probe_wait_ui");
    engineEnded = dlsym(image, "agy_engine_ended");
    sessionTerminal = dlsym(image, "agy_session_terminal");
    if (!start || !resumeUI || !waitUI || !engineEnded || !sessionTerminal) {
        dlclose(image); return ENOEXEC;
    }
    const char *const *env = (const char *const *)environmentVariables(ios_currentPid());
    size_t count = 0;
    while (env && env[count]) ++count;
    char **vector = calloc(count + 6, sizeof(*vector));
    if (!vector) { dlclose(image); return ENOMEM; }
    size_t pos = 2;
    vector[0] = strdup("agy");
    if (!vector[0]) goto alloc_failed;
    for (size_t n = 0; n < count; ++n) {
        if (strncmp(env[n], "AGY_CLI_DISABLE_AUTO_UPDATE=", sizeof("AGY_CLI_DISABLE_AUTO_UPDATE=")-1) == 0) continue;
        if (!(vector[pos++] = strdup(env[n]))) goto alloc_failed;
    }
    if (!(vector[pos++] = strdup("AGY_CLI_DISABLE_AUTO_UPDATE=true"))) goto alloc_failed;
    ++pos; // envp terminator, then Darwin's executable path
    if (!(vector[pos] = strdup(path.fileSystemRepresentation))) goto alloc_failed;
    // ios_system releases its dlopen reference at every command return. Keep
    // this adapter resident alongside the Go thread and its invocation state.
    Dl_info info;
    if (!dladdr((void *)&prepareEngine, &info) || !dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL)) {
        for (size_t n = 0; n < count + 6; ++n) free(vector[n]);
        free(vector);
        dlclose(image);
        return ENOEXEC;
    }
    startup = vector;
    entry = start;
    return 0;
alloc_failed:
    for (size_t n = 0; n < count + 6; ++n) free(vector[n]);
    free(vector);
    dlclose(image);
    return ENOMEM;
}

static void *runEngine(void *unused) {
    entry(1, startup);
    engineEnded();
    return NULL;
}

int agy_ios_main(int argc, char **argv) {
    @autoreleasepool {
        NSString *path = enginePath();
        if (argc == 2 && !strcmp(argv[1], "--version")) {
            NSBundle *bundle = [NSBundle bundleWithPath:path.stringByDeletingLastPathComponent];
            NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            if (!version) return 1;
            fprintf(thread_stdout, "%s\n", version.UTF8String);
            return 0;
        }
        if (argc != 1 || !ios_isatty(0) || !ios_isatty(1)) {
            fprintf(thread_stderr, "Usage: agy (interactive terminal) or agy --version\n");
            return 2;
        }
        if (pthread_mutex_trylock(&commandLock)) {
            fprintf(thread_stderr, "agy is already running in another terminal\n");
            return 1;
        }
        int cancellation;
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cancellation);
        int pager = ios_activePager(), interactive = ios_storeInteractive();
        int tty = ios_opentty();
        int input = tty >= 0 ? tty : fileno(thread_stdin);
        int flags = fcntl(input, F_GETFL);
        int error = reserveStreams();
        if (!error) error = prepareEngine(path);
        int width = 80, height = 24;
        ios_getWindowSize(&width, &height, ios_getContext());
        if (!error && (dup2(input, Input) < 0 || dup2(fileno(thread_stdout), UIOut) < 0 ||
                      dup2(fileno(thread_stderr), UIErr) < 0)) error = errno;
        if (!error) {
            sessionTerminal(1, Input, UIOut, width > 0 ? width : 80, height > 0 ? height : 24);
            ios_startInteractive();
            if (!invocation) {
                pthread_t worker;
                error = pthread_create(&worker, NULL, runEngine, NULL);
                if (!error) pthread_detach(worker);
            } else {
                error = resumeUI();
            }
            if (!error) error = waitUI(++invocation, 0);
        }
        if (entry) sessionTerminal(0, -1, -1, 0, 0);
        if (nullFD >= 0) {
            dup2(nullFD, Input);
            dup2(nullFD, UIOut);
            dup2(nullFD, UIErr);
        }
        if (flags >= 0) fcntl(input, F_SETFL, flags);
        if (!interactive) ios_stopInteractive();
        if (tty >= 0 && !pager) ios_closetty();
        if (error) fprintf(thread_stderr, "agy: %s\n", strerror(error));
        pthread_mutex_unlock(&commandLock);
        pthread_setcancelstate(cancellation, NULL);
        return error ? 1 : 0;
    }
}

#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <pthread.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct invocation {
    void (*start)(int, char **);
    int argc;
    char **argv;
    FILE *log;
};

static void *run_command(void *arg) {
    struct invocation *command = arg;
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    fprintf(command->log, "Command thread %llu\n", (unsigned long long)tid);
    command->start(command->argc, command->argv);
    return NULL;
}

int main(int argc, char **argv, char **envp) {
    int acp = argc == 5 && strcmp(argv[2], "acp") == 0;
    int pipes = argc == 7 && strcmp(argv[2], "pipe-gate") == 0;
    int gate = pipes || (argc == 5 && strcmp(argv[2], "tui-gate") == 0);
    int tui = gate || (argc == 4 && strcmp(argv[2], "tui") == 0);
    if (!acp && !tui && argc != 2 && (argc != 3 || strcmp(argv[2], "--version"))) return 2;
    FILE *host_log = fdopen(dup(STDERR_FILENO), "w");
    if (!host_log) return 1;
    setvbuf(host_log, NULL, _IONBF, 0);
    fprintf(host_log, "Probe host pid %ld\n", (long)getpid());
    if (pipes && !freopen(argv[6], "r", stdin)) return 1;
    int original[3];
    for (int fd = 0; fd < 3; ++fd) {
        original[fd] = dup(fd);
        if (original[fd] < 0) return 1;
    }
    // Only this disposable host lends its process stdio to the Go executable.
    if (acp && (!freopen(argv[3], "r", stdin) || !freopen(argv[4], "w", stdout))) {
        perror("ACP test pipes");
        return 1;
    }
    int input = -1, output = -1;
    if (pipes) {
        input = open(argv[3], O_RDONLY);
        output = open(argv[5], O_WRONLY);
        if (input < 0 || output < 0 || dup2(input, 0) < 0 || dup2(output, 1) < 0) return 1;
    } else if (tui) {
        setsid();
        int terminal = open(argv[3], O_RDWR);
        if (terminal < 0) return 1;
        if (ioctl(terminal, TIOCSCTTY, 0) < 0) {
            perror("TUI controlling terminal");
            return 1;
        }
        for (int fd = 0; fd < 3; ++fd) {
            if (dup2(terminal, fd) < 0) return 1;
        }
        if (terminal > 2) close(terminal);
    }
    void *engine = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (engine == NULL) {
        fprintf(host_log, "Loading AgyEngine: %s\n", dlerror());
        return 1;
    }
    fprintf(host_log, "AgyEngine loaded and host retained control\n");
    if (argc == 3 || acp || tui) {
        void (*start)(int, char **) = dlsym(engine, "agy_probe_process_entry");
        if (!start) {
            fprintf(host_log, "Missing agy process entry: %s\n", dlerror());
            return 1;
        }
        size_t count = 0;
        while (envp[count]) ++count;
        // Go's Darwin startup consumes argv, envp, and apple vectors in sequence.
        char **startup = calloc(count + 6, sizeof(*startup));
        if (!startup) return 1;
        startup[0] = "agy";
        int engine_argc = tui ? 1 : 2;
        if (!tui) startup[1] = argv[2];
        memcpy(startup + engine_argc + 1, envp, count * sizeof(*envp));
        startup[count + engine_argc + 2] = argv[1];
        fprintf(host_log, "Host entering agy\n");
        fflush(stdout);
        struct invocation command = {start, engine_argc, startup, host_log};
        if (gate) {
            int (*wait_ui)(unsigned, unsigned) = dlsym(engine, "agy_probe_wait_ui");
            int (*resume_ui)(void) = dlsym(engine, "agy_probe_resume_ui");
            void (*pipe_terminal)(int, unsigned short, unsigned short) = dlsym(engine, "agy_probe_pipe_terminal");
            FILE *control = fopen(argv[4], "r");
            if (!wait_ui || !resume_ui || !control) {
                fprintf(host_log, "Missing UI rendezvous: %s\n", dlerror());
                return 1;
            }
            if (pipes) {
                if (!pipe_terminal) return 1;
                pipe_terminal(1, 100, 32);
            }
            pthread_t worker;
            if (pthread_create(&worker, NULL, run_command, &command)) return 1;
            pthread_detach(worker);
            for (unsigned attempt = 1; attempt <= 3; ++attempt) {
                int result = wait_ui(attempt, 120);
                if (result) {
                    fprintf(host_log, "UI return timed out/error %d on attempt %u\n", result, attempt);
                    return 1;
                }
                int engine_errors = dup(2);
                if (engine_errors < 0) return 1;
                if (pipes) pipe_terminal(0, 0, 0);
                for (int fd = 0; fd < 3; ++fd)
                    if (dup2(original[fd], fd) < 0) return 1;
                // Real host-side work after UI cleanup and descriptor restoration.
                char cwd[4096];
                if (!getcwd(cwd, sizeof(cwd))) return 1;
                if (pipes) {
                    struct pollfd ready = {.fd = 0, .events = POLLIN};
                    char sentinel;
                    if (poll(&ready, 1, 3000) != 1 || read(0, &sentinel, 1) != 1 || sentinel != 'H') {
                        fprintf(host_log, "Host input was not restored on attempt %u\n", attempt);
                        return 1;
                    }
                }
                printf("HOST-COMMAND-OK %u\n", attempt);
                fflush(stdout);
                if (attempt == 3) { close(engine_errors); break; }
                if (fgetc(control) != 'R') return 1;
                if (pipes) {
                    if (dup2(input, 0) < 0 || dup2(output, 1) < 0) return 1;
                    pipe_terminal(1, 100, 32);
                } else {
                    int terminal = open(argv[3], O_RDWR);
                    if (terminal < 0) return 1;
                    for (int fd = 0; fd < 2; ++fd)
                        if (dup2(terminal, fd) < 0) return 1;
                    if (terminal > 2) close(terminal);
                }
                // Go redirected its diagnostics to a log file. Preserve that
                // destination across invocations instead of displaying logs.
                if (dup2(engine_errors, 2) < 0) return 1;
                close(engine_errors);
                if (resume_ui()) return 1;
            }
            // Only the disposable test host terminates here. An app would keep
            // this engine parked and retain the startup storage for its lifetime.
            return 0;
        }
        for (int attempt = 1; attempt <= ((acp || tui) ? 1 : 2); ++attempt) {
            pthread_t worker;
            fprintf(host_log, "Starting agy %d\n", attempt);
            fflush(stdout);
            if (pthread_create(&worker, NULL, run_command, &command) != 0) return 1;
            if (pthread_join(worker, NULL) != 0) return 1;
            fprintf(host_log, "Host resumed after agy %d\n", attempt);
            fflush(stdout);
        }
        free(startup);
    }
    return 0;
}

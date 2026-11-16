#include <dlfcn.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct invocation {
    void (*start)(int, char **);
    char **argv;
    FILE *log;
};

static void *run_command(void *arg) {
    struct invocation *command = arg;
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    fprintf(command->log, "Command thread %llu\n", (unsigned long long)tid);
    command->start(2, command->argv);
    return NULL;
}

int main(int argc, char **argv, char **envp) {
    int acp = argc == 5 && strcmp(argv[2], "acp") == 0;
    if (!acp && argc != 2 && (argc != 3 || strcmp(argv[2], "--version"))) return 2;
    FILE *host_log = fdopen(dup(STDERR_FILENO), "w");
    if (!host_log) return 1;
    setvbuf(host_log, NULL, _IONBF, 0);
    // Only this disposable host lends its process stdio to the Go executable.
    if (acp && (!freopen(argv[3], "r", stdin) || !freopen(argv[4], "w", stdout))) {
        perror("ACP test pipes");
        return 1;
    }
    void *engine = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (engine == NULL) {
        fprintf(host_log, "Loading AgyEngine: %s\n", dlerror());
        return 1;
    }
    fprintf(host_log, "AgyEngine loaded and host retained control\n");
    if (argc == 3 || acp) {
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
        startup[1] = argv[2];
        memcpy(startup + 3, envp, count * sizeof(*envp));
        startup[count + 4] = argv[1];
        fprintf(host_log, "Host entering agy\n");
        fflush(stdout);
        struct invocation command = {start, startup, host_log};
        for (int attempt = 1; attempt <= (acp ? 1 : 2); ++attempt) {
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

#include <dlfcn.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct invocation {
    void (*start)(int, char **);
    char **argv;
};

static void *run_command(void *arg) {
    struct invocation *command = arg;
    command->start(2, command->argv);
    return NULL;
}

int main(int argc, char **argv, char **envp) {
    int acp = argc == 5 && strcmp(argv[2], "acp") == 0;
    if (!acp && argc != 2 && (argc != 3 || strcmp(argv[2], "--version"))) return 2;
    // Only this disposable host lends its process stdio to the Go executable.
    if (acp && (!freopen(argv[3], "r", stdin) || !freopen(argv[4], "w", stdout))) {
        perror("ACP test pipes");
        return 1;
    }
    void *engine = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (engine == NULL) {
        fprintf(stderr, "Loading AgyEngine: %s\n", dlerror());
        return 1;
    }
    fprintf(stderr, "AgyEngine loaded and host retained control\n");
    if (argc == 3 || acp) {
        void (*start)(int, char **) = dlsym(engine, "agy_probe_process_entry");
        if (!start) {
            fprintf(stderr, "Missing agy process entry: %s\n", dlerror());
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
        fprintf(stderr, "Host entering agy\n");
        fflush(stdout);
        struct invocation command = {start, startup};
        for (int attempt = 1; attempt <= (acp ? 1 : 2); ++attempt) {
            pthread_t worker;
            fprintf(stderr, "Starting agy %d\n", attempt);
            fflush(stdout);
            if (pthread_create(&worker, NULL, run_command, &command) != 0) return 1;
            if (pthread_join(worker, NULL) != 0) return 1;
            fprintf(stderr, "Host resumed after agy %d\n", attempt);
            fflush(stdout);
        }
        free(startup);
    }
    return 0;
}

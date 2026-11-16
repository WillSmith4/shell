#include <dlfcn.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct invocation {
    void (*start)(int, char **);
    char **argv;
};

static void *run_version(void *arg) {
    struct invocation *command = arg;
    command->start(2, command->argv);
    return NULL;
}

int main(int argc, char **argv, char **envp) {
    if (argc != 2 && (argc != 3 || strcmp(argv[2], "--version"))) return 2;
    void *engine = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (engine == NULL) {
        fprintf(stderr, "Loading AgyEngine: %s\n", dlerror());
        return 1;
    }
    puts("AgyEngine loaded and host retained control");
    if (argc == 3) {
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
        startup[1] = "--version";
        memcpy(startup + 3, envp, count * sizeof(*envp));
        startup[count + 4] = argv[1];
        puts("Host entering agy");
        fflush(stdout);
        struct invocation command = {start, startup};
        for (int attempt = 1; attempt <= 2; ++attempt) {
            pthread_t worker;
            printf("Starting agy %d\n", attempt);
            fflush(stdout);
            if (pthread_create(&worker, NULL, run_version, &command) != 0) return 1;
            if (pthread_join(worker, NULL) != 0) return 1;
            printf("Host resumed after agy %d\n", attempt);
            fflush(stdout);
        }
        free(startup);
    }
    return 0;
}

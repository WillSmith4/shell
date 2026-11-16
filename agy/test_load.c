#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
        start(2, startup);
        puts("Host resumed after agy");
        free(startup);
    }
    return 0;
}

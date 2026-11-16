#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *engine = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (engine == NULL) {
        fprintf(stderr, "Loading AgyEngine: %s\n", dlerror());
        return 1;
    }
    puts("AgyEngine loaded and host retained control");
    return 0;
}

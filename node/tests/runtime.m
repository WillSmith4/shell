#import <Foundation/Foundation.h>
#include "ios_system.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <sys/ucontext.h>

static void dump_native_failure(int number, siginfo_t *info, void *context) {
    (void)info;
    ucontext_t *machine = context;
    uintptr_t pc = machine->uc_mcontext->__ss.__pc;
    Dl_info image = {0};
    dladdr((void *)pc, &image);
    dprintf(2, "Native failure signal %d pc=%p image=%s base=%p offset=%llu\n",
            number, (void *)pc, image.dli_fname ?: "?", image.dli_fbase,
            (unsigned long long)(pc - (uintptr_t)image.dli_fbase));
    void *frames[80];
    int count = backtrace(frames, 80);
    backtrace_symbols_fd(frames, count, 2);
    _exit(128 + number);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    @autoreleasepool {
        alarm(180);
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        if (![NSFileManager.defaultManager changeCurrentDirectoryPath:root]) return 2;
        setenv("HOME", root.UTF8String, 1);
        setenv("PATH", [root stringByAppendingPathComponent:@"bin"].UTF8String, 1);
        setenv("APPDIR", root.UTF8String, 1);
        setenv("GEMINI_CLI_NO_RELAUNCH", "true", 1);
        initializeEnvironment();
        static const char session[] = "node-runtime-test";
        ios_switchSession(session);
        ios_setContext(session);
        FILE *input = fopen("/dev/null", "r");
        FILE *output = fopen("runtime-output.txt", "w+");
        FILE *errors = fopen("runtime-errors.txt", "w+");
        if (!input || !output || !errors) return 2;
        ios_setStreams(input, output, errors);
        ios_useNativeTTY(true);
        joinMainThread = true;
        const char *commands[] = {
            "node --version",
            "node wasm.cjs",
            "node gemini/launcher.mjs --version",
            "node gemini/launcher.mjs --help",
            "node host.mjs",
            "node shell.mjs",
            "node -p 42",
            NULL
        };
        if (getenv("ASHELL_GEMINI_FIRST")) {
            commands[1] = "node gemini/launcher.mjs --version";
            commands[2] = "node wasm.cjs";
        }
        for (int n = 0; commands[n]; ++n) {
            struct sigaction action = {0};
            action.sa_sigaction = dump_native_failure;
            action.sa_flags = SA_SIGINFO;
            sigemptyset(&action.sa_mask);
            sigaction(SIGILL, &action, NULL);
            sigaction(SIGSEGV, &action, NULL);
            sigaction(SIGABRT, &action, NULL);
            int status = ios_system(commands[n]);
            fflush(output); fflush(errors);
            printf("%s: status %d\n", commands[n], status);
            if (status != 0) return 1;
        }
        fclose(input); fclose(output); fclose(errors);
        puts("PASS native Node, WASM, HTTPS, Gemini files and shell service");
    }
    return 0;
}

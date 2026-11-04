#import <Foundation/Foundation.h>
#include "ios_system.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <sys/ucontext.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdatomic.h>

static atomic_bool interactive_finished;
static atomic_bool interactive_ready;
static int terminal_mode;
static int terminal_writer;
static FILE *terminal_output;

// The app's Swift terminal supplies these callbacks to ios_system. The harness
// uses the same pipe-backed terminal and captures its output for assertions.
int storeInteractive(void) { return terminal_mode; }
void startInteractive(void) { terminal_mode = 1; }
void stopInteractive(void) { terminal_mode = 0; }

static void *exercise_interactive(void *unused) {
    (void)unused;
    char captured[65536];
    bool selected_key = false;
    for (int attempt = 0; attempt < 900 && !atomic_load(&interactive_finished); ++attempt) {
        struct stat metadata;
        if (fstat(fileno(terminal_output), &metadata) != 0) _exit(2);
        off_t size = metadata.st_size;
        off_t start = size > sizeof(captured) - 1 ? size - sizeof(captured) + 1 : 0;
        ssize_t count = pread(fileno(terminal_output), captured, sizeof(captured) - 1, start);
        if (count > 0) {
            captured[count] = 0;
            if (!selected_key && strstr(captured, "Use Gemini API Key")) {
                // Move from Google login to the API-key option, without logging in.
                usleep(300000);
                if (write(terminal_writer, "\033[B", 3) != 3) _exit(2);
                usleep(300000);
                if (write(terminal_writer, "\r", 1) != 1) _exit(2);
                selected_key = true;
            } else if (selected_key && strstr(captured, "Enter Gemini API Key")) {
                atomic_store(&interactive_ready, true);
                write(terminal_writer, "\003", 1);
                usleep(300000);
                write(terminal_writer, "\003", 1);
                return NULL;
            }
        }
        usleep(100000);
    }
    if (!atomic_load(&interactive_finished)) {
        fputs("Interactive Gemini did not reach its API key dialog.\n", stderr);
        _exit(2);
    }
    return NULL;
}

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
        setenv("NPM_CONFIG_CACHE", [root stringByAppendingPathComponent:@"npm-cache"].UTF8String, 1);
        setenv("NPM_CONFIG_PREFIX", root.UTF8String, 1);
        initializeEnvironment();
        static const char session[] = "node-runtime-test";
        ios_switchSession(session);
        ios_setContext(session);
        FILE *input = fopen("/dev/null", "r");
        FILE *output = fopen("runtime-output.txt", "w+");
        FILE *errors = fopen("runtime-errors.txt", "w+");
        if (!input || !output || !errors) return 2;
        if (getenv("ASHELL_INTERACTIVE_ONLY")) {
            int descriptors[2];
            if (pipe(descriptors)) return 2;
            fclose(input);
            input = fdopen(descriptors[0], "r");
            terminal_writer = descriptors[1];
            terminal_output = output;
            ios_setStreams(input, output, errors);
            ios_settty(input);
            ios_setWindowSize(100, 35, session);
            ios_useNativeTTY(false);
            joinMainThread = true;
            if (ios_system("node intl.cjs") != 0) return 1;
            setenv("GEMINI_CLI_TRUST_WORKSPACE", "true", 1);
            unsetenv("CI");
            pthread_t observer;
            if (pthread_create(&observer, NULL, exercise_interactive, NULL)) return 2;
            int status = ios_system("gemini");
            atomic_store(&interactive_finished, true);
            pthread_join(observer, NULL);
            fflush(output); fflush(errors);
            printf("Interactive gemini: status %d, API key dialog %d\n", status, atomic_load(&interactive_ready));
            if (!atomic_load(&interactive_ready) || (status != 0 && status != 130)) return 1;
            if (ios_system("gemini --version") || ios_system("node -p 42")) return 1;
            puts("PASS interactive Gemini rendering, keyboard navigation, exit and reentry");
            return 0;
        }
        ios_setStreams(input, output, errors);
        ios_useNativeTTY(true);
        joinMainThread = true;
        const char *commands[] = {
            "node --version",
            "node -p 42",
            "node intl.cjs",
            "node wasm.cjs",
            "npm --version",
            "npx --version",
            "dash -c 'node -p 42'",
            "dash -c 'npm --version && npx --version'",
            "gemini --version",
            "gemini --help",
            "node -e 'require(\"./npm/node_modules/cmd-shim\")(\"node_modules/ashell-npx-check/cli.cjs\",\"node_modules/.bin/ashell-npx-check\")'",
            "npx --offline --no ashell-npx-check",
            "npm run check --offline",
            "npx",
            "node gemini/launcher.mjs --version",
            "node gemini/launcher.mjs --help",
            "node host.mjs",
            "node shell.mjs",
            "dash -c 'echo OK'",
            "dash -c ':'",
            "dash -c 'printf \"hello world\\n\" > dash-regression.txt; cat dash-regression.txt'",
            "node -e 'process.env.ASHELL_GEMINI_TOOLS=\"1\";require(\"child_process\").spawn(\"sleep\",[\"20\"]);setTimeout(()=>process.exit(0),100)'",
            "node -p 42",
            NULL
        };
        if (getenv("ASHELL_GEMINI_FIRST")) {
            commands[0] = "gemini --version";
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
            if (strcmp(commands[n], "npx --offline --no ashell-npx-check") == 0) {
                NSString *result = [NSString stringWithContentsOfFile:@"npx-result.txt" encoding:NSUTF8StringEncoding error:NULL];
                if (![result isEqualToString:@"NPX_OK"]) return 1;
            }
        }
        NSString *contents = [NSString stringWithContentsOfFile:@"dash-regression.txt" encoding:NSUTF8StringEncoding error:NULL];
        if (![contents isEqualToString:@"hello world\n"]) return 1;
        contents = [NSString stringWithContentsOfFile:@"npx-result.txt" encoding:NSUTF8StringEncoding error:NULL];
        if (![contents isEqualToString:@"NPX_OK"]) return 1;
        for (int n = 0; n < 12; ++n) {
            if (ios_system("dash -c 'echo REENTRY'") != 0) return 1;
        }
        fclose(input); fclose(output); fclose(errors);
        puts("PASS native Node, WASM, HTTPS, Gemini files and shell service");
    }
    return 0;
}

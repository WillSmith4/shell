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
static int standard_writer;
static const char session[] = "node-runtime-test";
static FILE *terminal_output;
static atomic_int main_ticks;
extern void test_create_terminal(void);
extern void test_feed_terminal(const char *, size_t);
extern void test_terminal_key(const char *, size_t);

void test_send_bytes(const char *bytes, size_t length) {
    ios_switchSession(session);
    ios_setContext(session);
    int destination = ios_activePager() ? terminal_writer : standard_writer;
    if (write(destination, bytes, length) != length) _exit(2);
}

static void send_terminal_key(const char *bytes, size_t length) {
    // Match SceneDelegate's route on the UI thread, which initially has no
    // command session. stdin and the tty are separate pipes in the app.
    dispatch_sync(dispatch_get_main_queue(), ^{
        test_terminal_key(bytes, length);
    });
}

// The app's Swift terminal supplies these callbacks to ios_system. The harness
// uses the same pipe-backed terminal and captures its output for assertions.
int storeInteractive(void) {
    __block int result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = terminal_mode; });
    return result;
}
void startInteractive(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ terminal_mode = 1; });
}
void stopInteractive(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ terminal_mode = 0; });
}

static void *exercise_interactive(void *unused) {
    (void)unused;
    char captured[65536];
    bool selected_key = false;
    bool trusted_folder = false;
    for (int attempt = 0; attempt < 900 && !atomic_load(&interactive_finished); ++attempt) {
        struct stat metadata;
        if (fstat(fileno(terminal_output), &metadata) != 0) _exit(2);
        off_t size = metadata.st_size;
        off_t start = size > sizeof(captured) - 1 ? size - sizeof(captured) + 1 : 0;
        ssize_t count = pread(fileno(terminal_output), captured, sizeof(captured) - 1, start);
        if (count > 0) {
            captured[count] = 0;
            if (!trusted_folder && strstr(captured, "Do you trust the files in this folder?")) {
                send_terminal_key("\033[B", 3);
                usleep(300000);
                send_terminal_key("\033[A", 3);
                usleep(300000);
                send_terminal_key("\r", 1);
                trusted_folder = true;
            } else if (!selected_key && strstr(captured, "Use Gemini API Key")) {
                // Move from Google login to the API-key option, without logging in.
                usleep(300000);
                send_terminal_key("\033[B", 3);
                usleep(300000);
                send_terminal_key("\r", 1);
                selected_key = true;
            } else if (selected_key && strstr(captured, "Enter Gemini API Key")) {
                atomic_store(&interactive_ready, true);
                send_terminal_key("\003", 1);
                usleep(300000);
                send_terminal_key("\003", 1);
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

static int run_checks(int argc, char **argv) {
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
            standard_writer = descriptors[1];
            if (pipe(descriptors)) return 2;
            FILE *tty = fdopen(descriptors[0], "r");
            terminal_writer = descriptors[1];
            terminal_output = output;
            dispatch_sync(dispatch_get_main_queue(), ^{ test_create_terminal(); });
            // Production stdout is a pipe drained before UIKit renders it.
            int output_pipe[2];
            if (pipe(output_pipe)) return 2;
            output = fdopen(output_pipe[1], "w");
            int output_reader = output_pipe[0];
            dispatch_source_t reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                output_pipe[0], 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
            dispatch_source_set_event_handler(reader, ^{
                char bytes[8192];
                ssize_t count = read(output_reader, bytes, sizeof(bytes));
                if (count > 0) {
                    fwrite(bytes, 1, count, terminal_output);
                    fflush(terminal_output);
                    NSData *data = [NSData dataWithBytes:bytes length:count];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        test_feed_terminal(data.bytes, data.length);
                        atomic_fetch_add(&main_ticks, 1);
                    });
                }
            });
            dispatch_resume(reader);
            ios_setStreams(input, output, errors);
            ios_settty(tty);
            ios_setWindowSize(100, 35, session);
            ios_useNativeTTY(false);
            joinMainThread = true;
            if (ios_system("node intl.cjs") != 0) return 1;
            unsetenv("GEMINI_CLI_TRUST_WORKSPACE");
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
            "node missing-command.cjs",
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

int main(int argc, char **argv) {
    __block int result = 2;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = run_checks(argc, argv);
        dispatch_async(dispatch_get_main_queue(), ^{
            dprintf(STDERR_FILENO, "Main queue processed %d output updates\n", atomic_load(&main_ticks));
            result = status;
            CFRunLoopStop(CFRunLoopGetMain());
        });
    });
    // UIKit must execute on the physical main thread. dispatch_main() exits
    // that thread and may service its queue on a worker in a CLI executable.
    CFRunLoopRun();
    return result;
}

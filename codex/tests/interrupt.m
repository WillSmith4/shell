// Regression: ios_kill during a real exec request must release stderr and workers.
#import <Foundation/Foundation.h>
#include "ios_system.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char session[] = "codex-interrupt-regression";
static const char *ready_file;
static atomic_bool finished;

static void *interrupt_when_ready(void *unused) {
    (void)unused;
    for (int n = 0; n < 6000 && !atomic_load(&finished); ++n) {
        if (access(ready_file, F_OK) == 0) {
            ios_switchSession(session);
            ios_setContext(session);
            ios_kill();
            return NULL;
        }
        usleep(10000);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    @autoreleasepool {
        alarm(90);
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        [NSFileManager.defaultManager changeCurrentDirectoryPath:root];
        setenv("HOME", root.UTF8String, 1);
        setenv("GROUP", root.UTF8String, 1);
        setenv("CODEX_HOME", [root stringByAppendingPathComponent:@"home"].UTF8String, 1);
        setenv("PATH", [root stringByAppendingPathComponent:@"bin"].UTF8String, 1);
        ready_file = strdup([root stringByAppendingPathComponent:@"ready"].UTF8String);
        initializeEnvironment();
        ios_switchSession(session);
        ios_setContext(session);
        FILE *input = fopen("/dev/null", "r");
        FILE *output = fopen("output.txt", "w+");
        FILE *errors = fopen("errors.txt", "w+");
        if (!input || !output || !errors) return 2;
        ios_setStreams(input, output, errors);
        ios_useNativeTTY(true);
        joinMainThread = true;
        if (ios_system("codex --version") != 0) return 3;
        pthread_t sender;
        if (pthread_create(&sender, NULL, interrupt_when_ready, NULL)) return 4;
        int status = ios_system("codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox wait");
        atomic_store(&finished, true);
        pthread_join(sender, NULL);
        if (status != 130) { fprintf(stderr, "Expected 130, got %d\n", status); return 5; }
        for (int n = 0; n < 3; ++n) {
            if (ios_system("codex --version") != 0) return 6;
            if (ios_system("codex --help") != 0) return 7;
        }
        fflush(errors);
        char error_text[8192] = {0};
        pread(fileno(errors), error_text, sizeof(error_text) - 1, 0);
        if (strstr(error_text, "Cannot capture Codex stderr")) return 8;
        fclose(input); fclose(output); fclose(errors);
        puts("PASS interrupted exec and three same-process reentries");
        return 0;
    }
}

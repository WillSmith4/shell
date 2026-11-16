#import <Foundation/Foundation.h>
#include "ios_system.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static int interactive;
int storeInteractive(void) { return interactive; }
void startInteractive(void) { interactive = 1; }
void stopInteractive(void) { interactive = 0; }

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    @autoreleasepool {
        fprintf(stderr, "Probe host pid %d\n", getpid());
        FILE *control = fopen(argv[2], "r");
        if (!control || !freopen(argv[4], "r", stdin)) return 2;
        struct stat before[3];
        for (int fd = 0; fd < 3; fd++) if (fstat(fd, &before[fd])) return 2;
        initializeEnvironment();
        joinMainThread = true;
        const char session[] = "agy-integration";
        ios_switchSession(session);
        ios_setContext(session);
        ios_setWindowSize(100, 32, session);
        for (unsigned n = 1; n <= 3; ++n) {
            NSString *ttyName = [NSString stringWithFormat:@"%s-%u", argv[1], n];
            NSString *outName = [NSString stringWithFormat:@"%s-%u", argv[3], n];
            FILE *input = fopen("/dev/null", "r");
            FILE *tty = fopen(ttyName.fileSystemRepresentation, "r");
            FILE *output = fopen(outName.fileSystemRepresentation, "w");
            if (!input || !tty || !output) return 2;
            ios_setStreams(input, output, stderr);
            ios_settty(tty);
            int rc = ios_system("agy");
            if (rc || interactive) { fprintf(stderr,"agy returned %d, interactive %d\n", rc, interactive); return 1; }
            if (ios_system("agy --version")) return 1;
            fflush(output);
            for (int fd = 0; fd < 3; fd++) {
                struct stat now;
                if (fstat(fd, &now) || now.st_dev != before[fd].st_dev || now.st_ino != before[fd].st_ino) return 1;
            }
            if (fgetc(stdin) != 'H') return 1;
            fprintf(stderr, "HOST-COMMAND-OK %u\n", n);
            if (n < 3 && fgetc(control) != 'R') return 1;
            ios_settty(NULL);
            ios_setStreams(stdin, stdout, stderr);
            fclose(input); fclose(tty); fclose(output);
        }
    }
    return 0;
}

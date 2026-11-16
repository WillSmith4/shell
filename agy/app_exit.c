#include <pthread.h>
#include <unistd.h>
extern void agy_engine_ended(void);
// Report a terminal exit to the blocked caller, never terminate the app.
static void engine_exit(int status) __attribute__((noreturn));
static void engine_exit(int status) {
    agy_engine_ended();
    pthread_exit(NULL);
}
void exit(int status) { engine_exit(status); }
void _exit(int status) { engine_exit(status); }

/* Probe-only macOS facilities. Unsupported operations fail, never report success.
 * TLS certificate validation continues through the re-exported Security framework.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>

static void unsupported(const char *name) {
    fprintf(stderr, "AGY_PROBE_UNSUPPORTED: %s\n", name);
    errno = ENOSYS;
}

int32_t SecTrustSettingsSetTrustSettings(void *certificate, uint32_t domain, void *settings) {
    unsupported(__func__); return -4;
}
int32_t SecTrustSettingsRemoveTrustSettings(void *certificate, uint32_t domain) {
    unsupported(__func__); return -4;
}

const uint32_t kIOMainPortDefault = 0;
void *IOBSDNameMatching(uint32_t port, uint32_t options, const char *name) {
    unsupported(__func__); return 0;
}
uint32_t IOServiceGetMatchingService(uint32_t port, void *matching) {
    unsupported(__func__); return 0;
}
int32_t IOObjectRelease(uint32_t object) { return (int32_t)0xe00002c7; }
void *IORegistryEntryCreateCFProperty(uint32_t entry, void *key, void *allocator, uint32_t options) {
    unsupported(__func__); return 0;
}
int32_t IORegistryEntryGetParentEntry(uint32_t entry, const char *plane, uint32_t *parent) {
    if (parent) *parent = 0;
    unsupported(__func__); return (int32_t)0xe00002c7;
}

void *FSEventStreamCreate(void *allocator, void *callback, void *context, void *paths,
                        uint64_t since, double latency, uint32_t flags) {
    unsupported(__func__); return 0;
}
void *FSEventStreamCreateRelativeToDevice(void *allocator, void *callback, void *context,
                        int device, void *paths, uint64_t since, double latency, uint32_t flags) {
    unsupported(__func__); return 0;
}
void *FSEventStreamCopyDescription(void *stream) { return 0; }
void *FSEventStreamCopyPathsBeingWatched(void *stream) { return 0; }
void *FSEventsCopyUUIDForDevice(int device) { return 0; }
uint64_t FSEventsGetCurrentEventId(void) { return 0; }
uint64_t FSEventsGetLastEventIdForDeviceBeforeTime(int device, double time) { return 0; }
int FSEventStreamGetDeviceBeingWatched(void *stream) { return 0; }
uint64_t FSEventStreamGetLatestEventId(void *stream) { return 0; }
uint64_t FSEventStreamFlushAsync(void *stream) { return 0; }
void FSEventStreamFlushSync(void *stream) {}
void FSEventStreamInvalidate(void *stream) {}
void FSEventStreamRelease(void *stream) {}
void FSEventStreamSetDispatchQueue(void *stream, void *queue) {}
unsigned char FSEventStreamStart(void *stream) { unsupported(__func__); return 0; }
void FSEventStreamStop(void *stream) {}

#include <dispatch/dispatch.h>
#include <sys/param.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static unsigned syncCount;
static ino_t synchronizedInode;
static int synchronizedDescriptor;
static int observed_fsync(int descriptor) {
    struct stat status;
    if (fstat(descriptor, &status) != 0) abort();
    synchronizedInode = status.st_ino;
    synchronizedDescriptor = descriptor;
    syncCount++;
    return fsync(descriptor);
}
static void logf_(const char *format, ...) { (void)format; }
#define fsync observed_fsync
#include "../../vz/host/disk_image_io.inc"
#undef fsync
#define CHECK(expression) do { if (!(expression)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); return 1; } } while (0)

int main(void) {
    char directory[] = "/tmp/virtualmac-writeback-regression.XXXXXX";
    CHECK(mkdtemp(directory));
    char disk[MAXPATHLEN], other[MAXPATHLEN];
    snprintf(disk, sizeof disk, "%s/Disk.img", directory);
    snprintf(other, sizeof other, "%s/other.txt", directory);
    int first = open(disk, O_CREAT | O_RDWR, 0600);
    CHECK(first >= 0);
    struct stat original;
    CHECK(disk_image_fd(first, &original));

    // Queuing is deterministic: the worker cannot run until the original fd
    // has been closed and reused for another file.
    gDiskWritebackQueue = dispatch_queue_create("test.paused", DISPATCH_QUEUE_SERIAL);
    dispatch_suspend(gDiskWritebackQueue);
    disk_image_record_write(first, DISK_WRITEBACK_THRESHOLD);
    CHECK(gDiskWritebackInFlight == 1);
    close(first);
    int replacement = open(other, O_CREAT | O_RDWR, 0600);
    CHECK(replacement == first);
    struct stat replacementIdentity;
    CHECK(!disk_image_fd(replacement, &replacementIdentity));
    int reopened = open(disk, O_RDWR);
    struct stat reopenedIdentity;
    CHECK(reopened >= 0 && disk_image_fd(reopened, &reopenedIdentity));
    CHECK(reopenedIdentity.st_ino == original.st_ino);
    CHECK(disk_image_dup(replacement, &original) == -1);
    CHECK(disk_image_dup(replacement, &replacementIdentity) == -1);
    dispatch_resume(gDiskWritebackQueue);
    dispatch_sync(gDiskWritebackQueue, ^{});
    CHECK(syncCount == 1 && synchronizedInode == original.st_ino);
    CHECK(synchronizedDescriptor != replacement);
    errno = 0;
    CHECK(fcntl(synchronizedDescriptor, F_GETFD) == -1 && errno == EBADF);
    CHECK(gDiskWritebackInFlight == 0);
    puts("PASS queued fsync keeps Disk.img identity across close/reuse and closes its duplicate");

    errno = EDOM;
    CHECK(disk_image_pwrite(reopened, "ABC", 3, 0) == 3);
    CHECK(errno == EDOM);
    struct iovec vector = { .iov_base = "DEF", .iov_len = 3 };
    CHECK(disk_image_pwritev(reopened, &vector, 1, 3) == 3);
    char readback[7] = {0};
    CHECK(pread(reopened, readback, 6, 0) == 6);
    CHECK(strcmp(readback, "ABCDEF") == 0);
    CHECK(disk_image_pwrite(-1, "x", 1, 0) == -1 && errno == EBADF);
    CHECK(disk_image_pwritev(-1, &vector, 1, 0) == -1 && errno == EBADF);
    puts("PASS pwrite/pwritev return values, data, and errno stay native");

    uint64_t previousPending = gDiskWritebackPending;
    setenv("VZ_DISK_BACKGROUND_WRITEBACK", "0", 1);
    disk_image_record_write(reopened, DISK_WRITEBACK_THRESHOLD);
    CHECK(gDiskWritebackPending == previousPending && !gDiskWritebackInFlight);
    unsetenv("VZ_DISK_BACKGROUND_WRITEBACK");
    puts("PASS rollback switch disables background writeback");
    close(reopened);
    close(replacement);
    printf("evidence directory=%s (kept)\n", directory);
    return 0;
}

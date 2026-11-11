// Disk.img write-back. Guest barriers keep their native synchronization path;
// this worker reduces the cached backlog before a later guest barrier.
//
// Descriptor numbers are reusable, so every recorded write verifies both the
// Disk.img path and fstat identity. Each queued fsync owns a duplicate of that
// exact file and releases it after completion. No worker borrows a VMM fd.
// Set VZ_DISK_BACKGROUND_WRITEBACK=0 before launch to disable this optimization.
#include <sys/stat.h>

#define DISK_WRITEBACK_THRESHOLD (20ULL << 20)

static pthread_mutex_t gDiskWritebackLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t gDiskWritebackPending;
static int gDiskWritebackInFlight;
static dev_t gDiskWritebackDevice;
static ino_t gDiskWritebackInode;
static int gDiskWritebackIdentityKnown;
static dispatch_queue_t gDiskWritebackQueue;

typedef struct {
    int descriptor;
} DiskWritebackJob;

static int disk_image_fd(int fd, struct stat *identity) {
    char path[MAXPATHLEN];
    if (fd < 0 || fcntl(fd, F_GETPATH, path) != 0 ||
        fstat(fd, identity) != 0 || !S_ISREG(identity->st_mode))
        return 0;
    const char *slash = strrchr(path, '/');
    return strcmp(slash ? slash + 1 : path, "Disk.img") == 0;
}

static int disk_image_dup(int fd, const struct stat *identity) {
    int pinned = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (pinned < 0) return -1;
    struct stat duplicateIdentity;
    if (!disk_image_fd(pinned, &duplicateIdentity) ||
        duplicateIdentity.st_dev != identity->st_dev ||
        duplicateIdentity.st_ino != identity->st_ino) {
        close(pinned);
        return -1;
    }
    return pinned;
}

// Runs on the serial write-back queue. Calls from this image reach real fsync
// and close; the interposed write functions below preserve every guest result.
static void disk_writeback_run(void *context) {
    DiskWritebackJob *job = context;
    if (fsync(job->descriptor) != 0)
        logf_("[vmmhook] Disk.img background fsync failed errno=%d", errno);
    close(job->descriptor);
    free(job);
    pthread_mutex_lock(&gDiskWritebackLock);
    gDiskWritebackInFlight = 0;
    pthread_mutex_unlock(&gDiskWritebackLock);
}

static void disk_image_record_write(int fd, ssize_t result) {
    if (result <= 0) return;
    const char *enabled = getenv("VZ_DISK_BACKGROUND_WRITEBACK");
    if (enabled && strcmp(enabled, "0") == 0) return;
    struct stat identity;
    if (!disk_image_fd(fd, &identity)) return;

    pthread_mutex_lock(&gDiskWritebackLock);
    if (!gDiskWritebackIdentityKnown ||
        gDiskWritebackDevice != identity.st_dev ||
        gDiskWritebackInode != identity.st_ino) {
        gDiskWritebackDevice = identity.st_dev;
        gDiskWritebackInode = identity.st_ino;
        gDiskWritebackIdentityKnown = 1;
        gDiskWritebackPending = 0;
    }
    // Saturate the accounting rather than wrap after an extreme write count.
    gDiskWritebackPending = (uint64_t)result > UINT64_MAX - gDiskWritebackPending
        ? UINT64_MAX : gDiskWritebackPending + (uint64_t)result;
    DiskWritebackJob *job = NULL;
    if (gDiskWritebackPending >= DISK_WRITEBACK_THRESHOLD &&
        !gDiskWritebackInFlight) {
        int pinned = disk_image_dup(fd, &identity);
        if (pinned >= 0) {
            job = malloc(sizeof *job);
            if (!job) close(pinned);
            else {
                job->descriptor = pinned;
                if (!gDiskWritebackQueue)
                    gDiskWritebackQueue = dispatch_queue_create(
                        "virtualmac.disk-writeback",
                        dispatch_queue_attr_make_with_qos_class(
                            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
                gDiskWritebackPending = 0;
                gDiskWritebackInFlight = 1;
            }
        }
    }
    pthread_mutex_unlock(&gDiskWritebackLock);
    if (job) dispatch_async_f(gDiskWritebackQueue, job, disk_writeback_run);
}

static ssize_t disk_image_pwrite(int fd, const void *buffer, size_t length,
                                 off_t offset) {
    ssize_t result = pwrite(fd, buffer, length, offset);
    int savedErrno = errno;
    disk_image_record_write(fd, result);
    errno = savedErrno;
    return result;
}

static ssize_t disk_image_pwritev(int fd, const struct iovec *vectors,
                                  int count, off_t offset) {
    ssize_t result = pwritev(fd, vectors, count, offset);
    int savedErrno = errno;
    disk_image_record_write(fd, result);
    errno = savedErrno;
    return result;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_disk_image_io[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)&disk_image_pwrite, (const void *)&pwrite},
    {(const void *)&disk_image_pwritev, (const void *)&pwritev},
};

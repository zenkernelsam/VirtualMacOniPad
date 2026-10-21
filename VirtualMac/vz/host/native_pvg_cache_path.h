#pragma once

// Private candidate helper shared by the task interposer and the pure CPU
// filesystem tests. No directory creation, contents modification or fallback
// success is performed here. Cache contents remain Apple's native contents.
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define VZ_NATIVE_PVG_PATH_CAPACITY 4096

enum VZNativePVGCacheSelection {
    VZNativePVGCacheNotMapped = 0,
    VZNativePVGCacheStable = 1,
    VZNativePVGCacheTaskFallback = 2,
};

static bool VZNativePVGCacheComponent(const char *component) {
    if (!component || !*component || !strcmp(component, ".") ||
        !strcmp(component, "..")) return false;
    // Scope is build-generated lower-case ASCII; UID is generated decimal.
    // Components may not redirect traversal or contain terminal control bytes.
    for (const unsigned char *p = (const unsigned char *)component; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') ||
              *p == '-' || *p == '_')) return false;
    return true;
}

static bool VZNativePVGCacheDirectory(int fd, uid_t uid, bool privateUser) {
    struct stat s;
    if (fd < 0 || fstat(fd, &s) || !S_ISDIR(s.st_mode)) return false;
    if (privateUser)
        return s.st_uid == uid && (s.st_mode & 07777) == 0700;
    return (s.st_uid == 0 || s.st_uid == uid) && !(s.st_mode & 0022);
}

static bool VZNativePVGStableCachePath(const char *base, const char *scope,
    uid_t uid, char *result, size_t capacity) {
    if (!base || base[0] != '/' || !VZNativePVGCacheComponent(scope) ||
        !result || !capacity) return false;
    size_t baseLength = strlen(base);
    if (!baseLength || base[baseLength - 1] == '/') return false;
    char user[64];
    int count = snprintf(user, sizeof(user), "uid-%lu", (unsigned long)uid);
    if (count <= 0 || (size_t)count >= sizeof(user)) return false;
    count = snprintf(result, capacity, "%s/cache/native-pvg27/%s/%s/",
        base, user, scope);
    if (count <= 0 || (size_t)count >= capacity) return false;

    // base is the compile-time app-private path, never supplied by the guest.
    // O_NOFOLLOW protects its final component. /var is the system's canonical
    // /private/var alias; that static ancestor is not rewritten by this patch.
    int fd = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!VZNativePVGCacheDirectory(fd, uid, false)) {
        if (fd >= 0) close(fd);
        return false;
    }
    const char *components[] = {"cache", "native-pvg27", user, scope};
    for (size_t i = 0; i < sizeof(components) / sizeof(components[0]); ++i) {
        int next = openat(fd, components[i],
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd);
        fd = next;
        // cache parent may remain root-owned. The native cache subtree is
        // pre-created for the exact runtime UID with no extra permission bits.
        if (!VZNativePVGCacheDirectory(fd, uid, i > 0)) {
            if (fd >= 0) close(fd);
            return false;
        }
    }
    close(fd);
    return true;
}

static bool VZNativePVGTaskCachePath(const char *endpoint, char *result,
    size_t capacity) {
    // Preserve the existing random task/cache location when the stable tree
    // was not provisioned. Require the absolute endpoint shape established by
    // the parent transport. A malformed environment falls through to native.
    if (!endpoint || endpoint[0] != '/' || !result || !capacity) return false;
    const char *slash = strrchr(endpoint, '/');
    if (!slash || slash == endpoint || strcmp(slash + 1, "endpoint")) return false;
    size_t parentLength = (size_t)(slash - endpoint);
    const char suffix[] = "/cache/";
    if (parentLength > capacity || sizeof(suffix) > capacity - parentLength)
        return false;
    memcpy(result, endpoint, parentLength);
    memcpy(result + parentLength, suffix, sizeof(suffix));
    return true;
}

static enum VZNativePVGCacheSelection VZNativePVGSelectCachePath(
    bool modernServer, int name, const char *base, const char *scope,
    uid_t actualUID, uid_t expectedUID, const char *endpoint,
    char *result, size_t capacity) {
    if (!modernServer || name != _CS_DARWIN_USER_CACHE_DIR)
        return VZNativePVGCacheNotMapped;
    if (actualUID == expectedUID &&
        VZNativePVGStableCachePath(base, scope, actualUID, result, capacity))
        return VZNativePVGCacheStable;
    if (VZNativePVGTaskCachePath(endpoint, result, capacity))
        return VZNativePVGCacheTaskFallback;
    return VZNativePVGCacheNotMapped;
}

static size_t VZNativePVGCacheConfstr(const char *path,
    char *buffer, size_t capacity) {
    // POSIX confstr length includes the terminating NUL, independent of
    // supplied capacity. The caller may query with NULL or capacity zero.
    size_t length = strlen(path) + 1;
    if (buffer && capacity) {
        size_t copyLength = length - 1;
        if (copyLength >= capacity) copyLength = capacity - 1;
        if (copyLength) memcpy(buffer, path, copyLength);
        buffer[copyLength] = '\0';
    }
    return length;
}

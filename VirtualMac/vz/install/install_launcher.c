#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../guest/SEPBridgeInjector.h"

// A setuid program must not locate what it executes from its own path, which
// a hard link elsewhere could change. Each package builds in its runtime root.
#ifndef VZ_RUNTIME_ROOT
#define VZ_RUNTIME_ROOT "/var/root/VirtualMac"
#endif
#define VZ_START_INSTALL VZ_RUNTIME_ROOT "/install/start-install.sh"

#define VZ_SEP_DIRECTORY "/var/jb/sepbridge"
#define VZ_SEP_TOKEN VZ_SEP_DIRECTORY "/host-token.bin"
#define VZ_SEP_PLIST VZ_SEP_DIRECTORY "/com.mac.virtual.sepbridge.host.plist"
#define VZ_SEP_JOB "user/501/com.mac.virtual.sepbridge.host"

static int decode_sep_token(const char *hex, unsigned char token[32])
{
    if (!hex || strlen(hex) != 64) return 0;
    for (size_t index = 0; index < 32; index++) {
        unsigned value = 0;
        for (size_t digit = 0; digit < 2; digit++) {
            char c = hex[index * 2 + digit];
            unsigned nibble;
            if (c >= '0' && c <= '9') nibble = (unsigned)(c - '0');
            else if (c >= 'a' && c <= 'f') nibble = (unsigned)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') nibble = (unsigned)(c - 'A' + 10);
            else return 0;
            value = (value << 4) | nibble;
        }
        token[index] = (unsigned char)value;
    }
    return 1;
}

static int sep_safe_path(const char *path, int directory, int executable)
{
    struct stat info;
    return lstat(path, &info) == 0 && info.st_uid == 0 &&
        !(info.st_mode & 0022) &&
        (directory ? S_ISDIR(info.st_mode) : S_ISREG(info.st_mode)) &&
        (!executable || access(path, X_OK) == 0);
}

static int sep_launchctl(const char *operation, const char *target)
{
    const char *tool = "/var/jb/usr/bin/launchctl";
    char *arguments[] = {(char *)tool, (char *)operation, (char *)target,
                        strcmp(operation, "bootstrap") == 0 ? VZ_SEP_PLIST : NULL,
                        NULL};
    char *environment[] = {"PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin", NULL};
    pid_t child = -1;
    int spawned = posix_spawn(&child, tool, NULL, NULL, arguments, environment);
    if (spawned) return spawned;
    int status = 0;
    for (unsigned tick = 0; tick < 50; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child)
            return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (waited < 0 && errno != EINTR) return 1;
        usleep(100000);
    }
    kill(child, SIGTERM);
    for (unsigned tick = 0; tick < 5; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno != EINTR)) return 75;
        usleep(100000);
    }
    kill(child, SIGKILL);
    for (unsigned tick = 0; tick < 5; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno != EINTR)) break;
        usleep(100000);
    }
    return 75;
}

static int start_sep_bridge(const char *hex)
{
    unsigned char token[32];
    if (!decode_sep_token(hex, token)) {
        fprintf(stderr, "sepbridge: expected exactly 64 hexadecimal characters\n");
        return 2;
    }
    if (setgid(0) || setuid(0) || getuid() || geteuid()) {
        fprintf(stderr, "sepbridge: root privileges unavailable\n"); return 1;
    }
    if (!sep_safe_path(VZ_SEP_DIRECTORY, 1, 0) ||
        !sep_safe_path(VZ_SEP_DIRECTORY "/sepbridge-helper", 0, 1) ||
        !sep_safe_path(VZ_SEP_DIRECTORY "/sepinject.dylib", 0, 0) ||
        !sep_safe_path(VZ_SEP_PLIST, 0, 0) ||
        !VMSEPTrustedInjector() ||
        !sep_safe_path("/var/jb/usr/bin/launchctl", 0, 1)) {
        fprintf(stderr, "sepbridge: missing or unsafe root-owned component\n");
        return 78;
    }
    char temporary[] = VZ_SEP_DIRECTORY "/.host-token.XXXXXX";
    int fd = mkstemp(temporary);
    if (fd < 0) return 1;
    size_t offset = 0;
    int ok = fchmod(fd, 0600) == 0 && fchown(fd, 0, 0) == 0;
    while (ok && offset < sizeof(token)) {
        ssize_t count = write(fd, token + offset, sizeof(token) - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = 0; break; }
        offset += (size_t)count;
    }
    if (ok) ok = fsync(fd) == 0;
    close(fd);
    memset(token, 0, sizeof(token));
    if (!ok || rename(temporary, VZ_SEP_TOKEN) != 0) {
        fprintf(stderr, "sepbridge: token update failed; staging retained\n");
        return 1;
    }
    // The prior project relay was verified at user/501/com.vm.sepbridge. Its
    // sockets occupy these same ports. Retire only that own job, preserve its
    // plist, and leave the native akd and its existing mapping untouched.
    if (sep_launchctl("print", "user/501/com.vm.sepbridge") == 0) {
        if (sep_launchctl("disable", "user/501/com.vm.sepbridge") != 0 ||
            sep_launchctl("bootout", "user/501/com.vm.sepbridge") != 0) {
            fprintf(stderr,"sepbridge: legacy own relay retirement failed\n"); return 1;
        }
    }
    // Touch only our own job. A live helper reads the fresh token per request.
    if (sep_launchctl("print", VZ_SEP_JOB) != 0 &&
        sep_launchctl("bootstrap", "user/501") != 0) {
        fprintf(stderr, "sepbridge: own job bootstrap failed\n"); return 1;
    }
    int result = sep_launchctl("kickstart", VZ_SEP_JOB);
    printf("sepbridge: own job launch status=%d; native link requires verification\n", result);
    return result;
}

static int stop_sep_bridge(void)
{
    if (setgid(0) || setuid(0) || getuid() || geteuid()) {
        fprintf(stderr, "sepbridge: root privileges unavailable\n"); return 1;
    }
    // No native process signal, unload, or hook removal. Existing akd pins
    // remain until natural process exit; only this package's relay is stopped.
    if (sep_safe_path(VZ_SEP_DIRECTORY, 1, 0)) {
        if (rename(VZ_SEP_TOKEN, VZ_SEP_DIRECTORY "/host-token.disabled") &&
            errno != ENOENT) return 1;
    }
    if (sep_launchctl("print", VZ_SEP_JOB) != 0) return 0;
    int result = sep_launchctl("bootout", VZ_SEP_JOB);
    printf("sepbridge: own relay stop status=%d; native pins unchanged\n", result);
    return result;
}

static int has_prefix(const char *value, const char *prefix)
{
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

static int is_decimal(const char *value)
{
    if (!*value)
        return 0;
    for (; *value; value++) {
        if (*value < '0' || *value > '9')
            return 0;
    }
    return 1;
}

static int has_suffix(const char *value, const char *suffix)
{
    size_t value_length = strlen(value);
    size_t suffix_length = strlen(suffix);
    return value_length >= suffix_length &&
        strcasecmp(value + value_length - suffix_length, suffix) == 0;
}

static int is_direct_child(const char *value, const char *parent)
{
    size_t parent_length = strlen(parent);
    return strncmp(value, parent, parent_length) == 0 &&
        value[parent_length] == '/' && value[parent_length + 1] != '\0' &&
        strchr(value + parent_length + 1, '/') == NULL;
}

static const char *bootstrap_tool(const char *rootless, const char *rootful)
{
    return access(rootless, X_OK) == 0 ? rootless : rootful;
}

int main(int argc, char **argv)
{
    if (argc == 3 && strcmp(argv[1], "--sepbridge-start") == 0)
        return start_sep_bridge(argv[2]);
    if (argc == 2 && strcmp(argv[1], "--sepbridge-stop") == 0)
        return stop_sep_bridge();
    if (argc == 2 && strcmp(argv[1], "--diagnose") == 0) {
        const char *script = VZ_START_INSTALL;
        struct stat info;
        printf("launcher uid=%u euid=%u gid=%u egid=%u\n",
               getuid(), geteuid(), getgid(), getegid());
        if (stat(script, &info) == 0) {
            printf("start-install mode=%04o uid=%u gid=%u executable=%d\n",
                   info.st_mode & 07777, info.st_uid, info.st_gid,
                   access(script, X_OK) == 0);
        } else {
            printf("start-install stat failed: errno=%d %s\n",
                   errno, strerror(errno));
        }
        if (setgid(0) != 0 || setuid(0) != 0) {
            printf("setuid failed: errno=%d %s\n", errno, strerror(errno));
            return 1;
        }
        printf("after-setuid uid=%u euid=%u gid=%u egid=%u\n",
               getuid(), geteuid(), getgid(), getegid());
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "--cancel-install") == 0) {
        const char *attempt = argv[3];
        if (!is_decimal(argv[2]) || !has_prefix(attempt,
                "/var/mobile/Media/VirtualMac/Installations/") ||
            !has_suffix(attempt, ".installation") ||
            strchr(attempt, '\n') || strchr(attempt, '\r') ||
            strstr(attempt, "/../") || has_suffix(attempt, "/..")) {
            fprintf(stderr, "install-launcher: invalid cancellation request\n");
            return 2;
        }
        if (setgid(0) != 0 || setuid(0) != 0) {
            fprintf(stderr, "install-launcher: cannot become root: %s\n",
                    strerror(errno));
            return 1;
        }
        pid_t process = (pid_t)strtol(argv[2], NULL, 10);
        if (process > 1)
            kill(-process, SIGTERM);
        usleep(500000);
        execl(bootstrap_tool("/var/jb/bin/rm", "/bin/rm"),
              "rm", "-rf", "--", attempt,
              (char *)NULL);
        return 1;
    }
    if (argc == 3 && strcmp(argv[1], "--delete-artifact") == 0) {
        const char *path = argv[2];
        const char *installations =
            "/var/mobile/Media/VirtualMac/Installations/";
        const char *images =
            "/var/mobile/Media/VirtualMac/Restore Images/";
        int allowed =
            (has_prefix(path, installations) &&
             strlen(path) > strlen(installations)) ||
            (has_prefix(path, images) && strlen(path) > strlen(images));
        if (!allowed || strchr(path, '\n') || strchr(path, '\r') ||
            strstr(path, "/../") || has_suffix(path, "/..")) {
            fprintf(stderr, "install-launcher: invalid artifact path\n");
            return 2;
        }
        if (setgid(0) != 0 || setuid(0) != 0) {
            fprintf(stderr, "install-launcher: cannot become root: %s\n",
                    strerror(errno));
            return 1;
        }
        execl(bootstrap_tool("/var/jb/bin/rm", "/bin/rm"),
              "rm", "-rf", "--", path,
              (char *)NULL);
        fprintf(stderr, "install-launcher: cleanup exec failed: %s\n",
                strerror(errno));
        return 1;
    }
    if (argc != 8) {
        fprintf(stderr, "install-launcher: expected seven arguments\n");
        return 2;
    }
    if (!has_prefix(argv[1],
            "/var/mobile/Media/VirtualMac/Restore Images/") ||
        !(has_suffix(argv[1], ".ipsw") || has_suffix(argv[1], ".zip")) ||
        !has_prefix(argv[2],
            "/var/mobile/Media/VirtualMac/Installations/") ||
        !has_suffix(argv[2], ".bundle.installing") ||
        !is_direct_child(argv[3], "/var/mobile/Media/VirtualMac") ||
        !has_suffix(argv[3], ".bundle") ||
        !has_prefix(argv[4],
            "/var/mobile/Media/VirtualMac/Installations/") ||
        !has_suffix(argv[4], ".install.log") ||
        !is_decimal(argv[5]) || !is_decimal(argv[6]) ||
        !is_decimal(argv[7])) {
        fprintf(stderr, "install-launcher: invalid output path\n");
        return 2;
    }
    for (int index = 1; index < argc; index++) {
        if (strchr(argv[index], '\n') || strchr(argv[index], '\r')) {
            fprintf(stderr, "install-launcher: newline in argument\n");
            return 2;
        }
        if (strstr(argv[index], "/../") ||
            has_suffix(argv[index], "/..")) {
            fprintf(stderr, "install-launcher: parent traversal in argument\n");
            return 2;
        }
    }
    int log_fd = open(argv[4], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (log_fd < 0)
        return 2;
    dup2(log_fd, STDOUT_FILENO);
    dup2(log_fd, STDERR_FILENO);
    close(log_fd);
    setlinebuf(stdout);
    setlinebuf(stderr);
    printf("INSTALL_LAUNCHER_BEGIN\tipsw=%s\n", argv[1]);

    struct stat info;
    if (stat(argv[1], &info) != 0 || !S_ISREG(info.st_mode)) {
        fprintf(stderr,
                "INSTALL_FAILED\tlauncher IPSW is not a regular file: %s\n",
                strerror(errno));
        return 2;
    }
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "INSTALL_FAILED\tlauncher cannot become root: %s\n",
                strerror(errno));
        return 1;
    }
    if (setenv("PATH",
               "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
               1) != 0) {
        fprintf(stderr, "INSTALL_FAILED\tlauncher cannot set PATH: %s\n",
                strerror(errno));
        return 1;
    }
    execl(bootstrap_tool("/var/jb/bin/sh", "/bin/sh"), "sh",
          VZ_START_INSTALL, argv[1],
          argv[2], argv[3], argv[4], argv[5], argv[6], argv[7],
          (char *)NULL);
    fprintf(stderr, "INSTALL_FAILED\tlauncher exec failed: %s\n",
            strerror(errno));
    return 1;
}

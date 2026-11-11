#ifndef VIRTUALMAC_SEPBRIDGE_INJECTOR_H
#define VIRTUALMAC_SEPBRIDGE_INJECTOR_H
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The only accepted injector alias is the installed Dopamine alias. Its
// canonical destination must equal the separately verified basebin image.
// Parameters are explicit solely so offline tests can use isolated fixtures.
static inline int VMSEPProtectedParent(const char *path)
{
    char parent[PATH_MAX];
    if (!path || strlen(path) >= sizeof(parent)) return 0;
    strcpy(parent,path);
    char *separator = strrchr(parent,'/');
    if (!separator) return 0;
    if (separator == parent) separator[1] = 0;
    else *separator = 0;
    struct stat info;
    return stat(parent,&info) == 0 && S_ISDIR(info.st_mode) &&
        info.st_uid == 0 && !(info.st_mode & 0022);
}
static inline int VMSEPTrustedInjectorAt(const char *alias, const char *expected)
{
    struct stat info;
    if (!alias || !expected || lstat(alias, &info) || info.st_uid != 0) return 0;
    if (S_ISREG(info.st_mode)) return !(info.st_mode & 0022) && access(alias, X_OK) == 0;
    if (!S_ISLNK(info.st_mode)) return 0;
    // Darwin link permission bits do not govern access to the destination.
    // Both root-owned parents and the resolved file must protect the alias.
    if (!VMSEPProtectedParent(alias) || !VMSEPProtectedParent(expected)) return 0;
    char actualPath[PATH_MAX], expectedPath[PATH_MAX];
    if (!realpath(alias, actualPath) || !realpath(expected, expectedPath) ||
        strcmp(actualPath, expectedPath)) return 0;
    if (lstat(actualPath, &info) || !S_ISREG(info.st_mode) ||
        info.st_uid != 0 || (info.st_mode & 0022) || access(actualPath, X_OK)) return 0;
    return 1;
}

static inline int VMSEPTrustedInjector(void)
{
    return VMSEPTrustedInjectorAt("/var/jb/usr/bin/opainject", "/var/jb/basebin/opainject");
}
#endif

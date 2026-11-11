#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <fcntl.h>
static int rootOwnership = 1;
static int mockStat(const char *path,struct stat *info) {
    int result = stat(path,info); if (!result && rootOwnership) info->st_uid = 0; return result;
}
static int mockLstat(const char *path,struct stat *info) {
    int result = lstat(path,info); if (!result && rootOwnership) info->st_uid = 0; return result;
}
#define stat(path,info) mockStat(path,info)
#define lstat(path,info) mockLstat(path,info)
#include "../../vz/guest/SEPBridgeInjector.h"
#undef stat
#undef lstat
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d\n",__LINE__); return 1; } } while (0)
int main(void) {
    char root[]="/tmp/vmsep-injector-test.XXXXXX";CHECK(mkdtemp(root));
    char alias[PATH_MAX],base[PATH_MAX],other[PATH_MAX];
    snprintf(alias,sizeof(alias),"%s/alias",root);
    snprintf(base,sizeof(base),"%s/basebin-opainject",root);
    snprintf(other,sizeof(other),"%s/other-alias",root);
    int fd=open(base,O_CREAT|O_WRONLY,0755);CHECK(fd>=0);close(fd);
    CHECK(chmod(base,0755)==0);CHECK(symlink("basebin-opainject",alias)==0);
    CHECK(VMSEPTrustedInjectorAt(alias,base));
    CHECK(symlink("unrelated",other)==0);CHECK(!VMSEPTrustedInjectorAt(other,base));
    rootOwnership=0;CHECK(!VMSEPTrustedInjectorAt(alias,base));rootOwnership=1;
    CHECK(chmod(root,0777)==0);CHECK(!VMSEPTrustedInjectorAt(alias,base));CHECK(chmod(root,0700)==0);
    CHECK(chmod(base,0777)==0);CHECK(!VMSEPTrustedInjectorAt(alias,base));CHECK(chmod(base,0755)==0);
    CHECK(VMSEPTrustedInjectorAt(base,base));
    puts("PASS trusted relative injector alias; wrong destination, owner and writable parent/target rejected");
    return 0;
}

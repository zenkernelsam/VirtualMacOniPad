/* vz_clonefile — APFS clonefile(2) wrapper for cloning a VM Disk.img
 * without copying its blocks (the iPad's bundled cp has no -c).
 *
 *   vz_clonefile <src> <dst>
 */
#include <stdio.h>
#include <sys/clonefile.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <src> <dst>\n", argv[0]);
        return 2;
    }
    if (clonefile(argv[1], argv[2], 0)) {
        perror("clonefile");
        return 1;
    }
    printf("cloned %s -> %s\n", argv[1], argv[2]);
    return 0;
}

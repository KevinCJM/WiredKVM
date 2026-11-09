/* Only the platform dirent ABI lives here; planning and validation are Rust. */
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

void *wk_tree_dir_open(int descriptor) {
    int duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
    if (duplicate < 0) return NULL;
    DIR *directory = fdopendir(duplicate);
    if (!directory) { int saved = errno; close(duplicate); errno = saved; }
    return directory;
}
/* -errno on failure, zero at end, positive UTF-8 byte length otherwise. */
int wk_tree_dir_next(void *directory, unsigned char *output, unsigned capacity) {
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir((DIR *)directory);
        if (!entry) return errno ? -errno : 0;
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        size_t count = strlen(entry->d_name);
        if (count == 0 || count > capacity) return -ERANGE;
        memcpy(output, entry->d_name, count);
        return (int)count;
    }
}
void wk_tree_dir_close(void *directory) { closedir((DIR *)directory); }

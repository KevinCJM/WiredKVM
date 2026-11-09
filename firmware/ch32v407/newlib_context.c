/* Single polling thread; ESP's generic RISC-V newlib needs a real reentrancy
 * object. Do not use the libnosys __getreent stub in a working firmware. */
#include <reent.h>
#include <errno.h>
#include <stddef.h>
#include <sys/types.h>
static struct _reent context = _REENT_INIT(context);
struct _reent *__getreent(void) { return &context; }
/* No heap or libc file/device I/O is allowed in the bridge. Error paths fail
 * explicitly instead of pulling in architecture-specific libnosys stubs. */
void *_sbrk(ptrdiff_t increment) { (void)increment; errno=ENOMEM; return (void *)-1; }
int _close(int fd) { (void)fd; errno=EBADF; return -1; }
ssize_t _read(int fd,void *data,size_t size) { (void)fd;(void)data;(void)size;errno=EBADF;return -1; }
ssize_t _write(int fd,const void *data,size_t size) { (void)fd;(void)data;(void)size;errno=EBADF;return -1; }
off_t _lseek(int fd,off_t offset,int whence) { (void)fd;(void)offset;(void)whence;errno=EBADF;return -1; }

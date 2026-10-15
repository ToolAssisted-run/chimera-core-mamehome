// Guest-only overrides for libc calls whose syscalls the miniBox surface
// rejects (by design: no host filesystem). Because the guest is one static
// link, defining these here means musl's versions are never pulled in.
// Everything reports a read-only, flat filesystem, which is what the sandbox
// is; MAME only reaches these from paths a headless machine does not take.
#include <cerrno>
#include <cstring>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

extern "C" {

int mkdir(const char *, mode_t) { errno = EROFS; return -1; }
int rmdir(const char *) { errno = EROFS; return -1; }
int unlink(const char *) { errno = EROFS; return -1; }
int rename(const char *, const char *) { errno = EROFS; return -1; }
int chmod(const char *, mode_t) { errno = EROFS; return -1; }
int chdir(const char *) { return 0; }

char *getcwd(char *buf, size_t size)
{
	if (!buf || size < 2) { errno = ERANGE; return nullptr; }
	buf[0] = '/';
	buf[1] = '\0';
	return buf;
}

}  // extern "C"

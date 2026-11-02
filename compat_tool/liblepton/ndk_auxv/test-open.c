/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define LEPTON_NDK_HOST_TEST
#define dladdr lepton_test_dladdr
#include "ndk_auxv.c"

static int guest;
static unsigned char fake_bridge[4096];
int *__errno(void) { return &errno; }
int __android_log_write(int level, const char *tag, const char *text) {
    (void)level; (void)tag; (void)text;
    return 0;
}
int lepton_test_dladdr(const void *caller, lepton_dl_info *info) {
    (void)caller;
    if (!guest) return 0;
    info->name = "/system/lib64/libndk_translation.so";
    info->base = fake_bridge;
    return 1;
}
int main(void) {
    memcpy(fake_bridge, "\177ELF\2\1", 6);
    memcpy(fake_bridge + 0x298, bridge_id, sizeof bridge_id);
    int fd = open("/proc/self/auxv", O_RDONLY);
    assert(fd >= 0); /* Native callers still receive real auxv. */
    char data[16];
    assert(read(fd, data, sizeof data) == sizeof data);
    close(fd);
    guest = 1;
    assert(open("/proc/self/auxv", O_RDONLY) == -1 && errno == EACCES);
    assert(openat(AT_FDCWD, "/proc/self/auxv", O_RDONLY) == -1 && errno == EACCES);
    char directory[] = "/tmp/lepton-open-test.XXXXXX";
    assert(mkdtemp(directory));
    int dirfd = open(directory, O_DIRECTORY | O_RDONLY);
    assert(dirfd >= 0);
    mode_t oldmask = umask(0);
    fd = openat(dirfd, "data", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0640u);
    umask(oldmask);
    assert(fd >= 0 && (fcntl(fd, F_GETFD) & FD_CLOEXEC));
    struct stat status;
    assert(fstat(fd, &status) == 0 && (status.st_mode & 0777) == 0640);
    assert(write(fd, "ok", 2) == 2);
    close(fd);
    fd = openat(dirfd, "data", O_RDONLY);
    assert(fd >= 0 && read(fd, data, 2) == 2 && !memcmp(data, "ok", 2));
    close(fd);
    assert(openat(dirfd, "missing", O_RDONLY) == -1 && errno == ENOENT);
    assert(unlinkat(dirfd, "data", 0) == 0);
    close(dirfd);
    assert(rmdir(directory) == 0);
    puts("PASS: guest-only auxv denial; native auxv, relative paths, mode, CLOEXEC, I/O and errno preserved");
}

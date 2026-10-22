/* x86_64 Linux, libc-free BinderFS diagnostic */
#include <linux/android/binderfs.h>
#include <asm/unistd.h>

static long sys3(long nr, long a, long b, long c)
{
    long result;
    __asm__ volatile("syscall"
        : "=a"(result)
        : "a"(nr), "D"(a), "S"(b), "d"(c)
        : "rcx", "r11", "memory");
    return result;
}

static void message(const char *s)
{
    unsigned long n = 0;
    while (s[n]) ++n;
    sys3(__NR_write, 2, (long)s, n);
}

static void error_number(long error)
{
    char digits[24];
    unsigned i = 0;
    unsigned long n = (unsigned long)-error;

    do {
        digits[i++] = '0' + (n % 10);
        n /= 10;
    } while (n);

    while (i)
        sys3(__NR_write, 2, (long)&digits[--i], 1);

    message("\n");
}

__attribute__((noreturn))
void binderfs_main(void)
{
    const char *names[] = {
        "binder", "hwbinder", "vndbinder"
    };
    const char *paths[] = {
        "/dev/binderfs/binder",
        "/dev/binderfs/hwbinder",
        "/dev/binderfs/vndbinder"
    };

    long fd = sys3(__NR_open,
        (long)"/dev/binderfs/binder-control", 0, 0);
    long status = 0;

    if (fd < 0) {
        message("OPEN binder-control errno=");
        error_number(fd);
        status = 1;
    } else {
        for (unsigned i = 0; i < 3; ++i) {
            if (sys3(__NR_access, (long)paths[i], 0, 0) == 0) {
                message("EXISTS: ");
                message(names[i]);
                message("\n");
                continue;
            }

            struct binderfs_device device;
            volatile unsigned char *p = (volatile unsigned char *)&device;
            for (unsigned k = 0; k < sizeof(device); ++k)
                p[k] = 0;
            for (unsigned j = 0; names[i][j]; ++j)
                device.name[j] = names[i][j];

            long rc = sys3(__NR_ioctl,
                fd, BINDER_CTL_ADD, (long)&device);

            if (rc < 0) {
                message("FAILED: ");
                message(names[i]);
                message(" errno=");
                error_number(rc);
                status = 1;
                break;
            }

            message("CREATED: ");
            message(names[i]);
            message("\n");
        }

        sys3(__NR_close, fd, 0, 0);
    }

    sys3(__NR_exit, status, 0, 0);
    __builtin_unreachable();
}


/* Linux enters _start with a 16-byte-aligned stack.
 * Align it explicitly before making a normal C function call.
 */
__asm__(
    ".global _start\n"
    "_start:\n"
    "xor %ebp, %ebp\n"
    "andq $-16, %rsp\n"
    "call binderfs_main\n"
    "ud2\n"
);

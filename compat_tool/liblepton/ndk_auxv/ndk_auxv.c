/* SPDX-License-Identifier: MIT
 * Compatibility with Google's API 34 r14 NDK bridge, build-id
 * 553ba82b76bb5a11fd1d67b2c7e01b75. No proprietary code is included.
 * See README.md in this directory for ABI verification and limitations.
 * Explicit Bionic declarations allow building with the existing AOSP Clang
 * without downloading an NDK sysroot. This library is x86_64 Android only.
 */
extern int strcmp(const char *, const char *);
extern int memcmp(const void *, const void *, __SIZE_TYPE__);
extern int clock_gettime(int, void *);
struct lepton_timespec { long sec, nsec; };

static int missing_register(unsigned instruction) {
    unsigned opcode = instruction & ~31u;
    return opcode == 0xd5380000u || /* MIDR_EL1 */
           opcode == 0xd53be000u || /* CNTFRQ_EL0 */
           opcode == 0xd53be040u;   /* CNTVCT_EL0 */
}

/* Return 0 for unhandled instructions, 1 for success, -1 for clock failure. */
static int emulate_register(unsigned instruction, unsigned long *regs,
                            unsigned long *pc) {
    if (!missing_register(instruction)) return 0;
    unsigned opcode = instruction & ~31u;
    unsigned long value;
    if (opcode == 0xd5380000u) {
        value = 0x410fd030; /* Generic Cortex-A53; do not claim Neoverse. */
    } else if (opcode == 0xd53be000u) {
        value = 1000000000UL; /* Counter ticks are CLOCK_MONOTONIC ns. */
    } else {
        struct lepton_timespec ts;
        if (clock_gettime(1, &ts)) return -1;
        value = (unsigned long)ts.sec * 1000000000UL + ts.nsec;
    }
    unsigned target = instruction & 31;
    if (target != 31) regs[target] = value; /* XZR discards the result. */
    *pc += 4;
    return 1;
}

#ifndef LEPTON_NDK_UNIT_TEST
#if (!defined(__ANDROID__) || !defined(__x86_64__)) && !defined(LEPTON_NDK_HOST_TEST)
#error This shim requires an x86_64 Android target
#endif
extern int *__errno(void);
extern int __android_log_write(int, const char *, const char *);
extern int unsetenv(const char *);
extern int setenv(const char *, const char *, int);
extern long syscall(long, ...);
extern int raise(int);
typedef struct {
    const char *name;
    void *base;
    const char *symbol;
    void *address;
} lepton_dl_info;
extern int dladdr(const void *, lepton_dl_info *);
#define EXPORT __attribute__((visibility("default")))
#define LOG(message) __android_log_write(4, "LeptonNdkAuxv", message)

static unsigned char *bridge_base;
static const unsigned char bridge_id[16] = {
    0x55,0x3b,0xa8,0x2b,0x76,0xbb,0x5a,0x11,
    0xfd,0x1d,0x67,0xb2,0xc7,0xe0,0x1b,0x75
};

/* Module addresses/state offsets below belong ONLY to this reviewed build.
 * Validate its ELF note before reading any private translator state.
 */
static unsigned char *bridge_for_caller(const void *caller) {
    unsigned char *base = __atomic_load_n(&bridge_base, __ATOMIC_ACQUIRE);
    if (base) return base;
    lepton_dl_info info = {0};
    if (!dladdr(caller, &info) || !info.name || !info.base) return 0;
    const char *name = info.name;
    for (const char *p = name; *p; p++) if (*p == '/') name = p + 1;
    if (strcmp(name, "libndk_translation.so")) return 0;
    base = info.base;
    if (memcmp(base, "\177ELF\2\1", 6) ||
        memcmp(base + 0x298, bridge_id, sizeof bridge_id)) {
        LOG("Unsupported NDK bridge build; refusing private ABI access");
        return 0;
    }
    __atomic_store_n(&bridge_base, base, __ATOMIC_RELEASE);
    return base;
}

__attribute__((constructor)) static void loaded(void) {
    /* The guest linker must not try to load this host-architecture preload. */
    unsetenv("LD_PRELOAD");
    /* Heavy optimization would compile unsupported registers without our
     * interpreter fallback. Keep the light JIT for all supported code. */
    setenv("NDK_TRANSLATION_MODE", "light-translate-or-interpret", 1);
    LOG("Native register/auxv compatibility shim loaded");
}

static int blocked_auxv(const char *path, const void *caller) {
    if (!path || strcmp(path, "/proc/self/auxv")) return 0;
    /* Do not use a cached module here: native callers must retain access. */
    lepton_dl_info info = {0};
    if (!dladdr(caller, &info) || !info.name) return 0;
    const char *name = info.name;
    for (const char *p = name; *p; p++) if (*p == '/') name = p + 1;
    if (strcmp(name, "libndk_translation.so")) return 0;
    bridge_for_caller(caller);
    LOG("Denied host auxv to ARM64 guest; using Android fallback");
    *__errno() = 13; /* EACCES, supported by Go's Android sysargs fallback. */
    return 1;
}

/* NDK bridge guest-open routines ultimately call these Bionic entrypoints.
 * Forward native flags directly to x86_64 openat(2), preserving mode/errno.
 * Do not interpose the bridge's guest-open symbols: they are namespace-local.
 */
EXPORT int openat(int fd, const char *path, int flags, ...) {
    if (blocked_auxv(path, __builtin_return_address(0))) return -1;
    __builtin_va_list ap;
    __builtin_va_start(ap, flags);
    unsigned mode = 0;
    if ((flags & 0x40) || (flags & 0x410000) == 0x410000)
        mode = __builtin_va_arg(ap, unsigned); /* O_CREAT or O_TMPFILE */
    __builtin_va_end(ap);
    return syscall(257, fd, path, flags, mode);
}
EXPORT int open(const char *path, int flags, ...) {
    if (blocked_auxv(path, __builtin_return_address(0))) return -1;
    __builtin_va_list ap;
    __builtin_va_start(ap, flags);
    unsigned mode = 0;
    if ((flags & 0x40) || (flags & 0x410000) == 0x410000)
        mode = __builtin_va_arg(ap, unsigned);
    __builtin_va_end(ap);
    return syscall(257, -100, path, flags, mode); /* AT_FDCWD */
}

EXPORT void fallback(void *)
    __asm__("_ZN15ndk_translation15LightTranslator13UndefinedInsnEv");
EXPORT void fallback(void *frontend) {
    unsigned char *base = bridge_for_caller(__builtin_return_address(0));
    if (!base) { raise(4); return; }
    /* success_ at 0x00. A failed translation discards the block and invokes
     * InterpretInsn. The original interpreter still handles (and rejects)
     * every opcode outside our three explicit register-read additions. */
    *(unsigned char *)frontend = 0;
}

EXPORT void interpret(void *)
    __asm__("_ZN15ndk_translation13InterpretInsnEPNS_12ProcessStateE");
EXPORT void interpret(void *state) {
    unsigned char *base = bridge_for_caller(__builtin_return_address(0));
    if (!base) { raise(4); return; }
    /* CPUState's X0..X30 begin at 0; insn_addr is at 0x310. */
    unsigned long *pc = (void *)((char *)state + 0x310);
    int result = emulate_register(*(unsigned *)*pc, state, pc);
    if (result < 0) { raise(4); return; }
    if (result) {
        static unsigned seen;
        if (__atomic_fetch_add(&seen, 1, __ATOMIC_RELAXED) < 4)
            LOG("Interpreted missing ARM system register");
        return;
    }
    void (*original)(void *) = (void *)(base + 0x1d3bc0);
    original(state);
}
#endif

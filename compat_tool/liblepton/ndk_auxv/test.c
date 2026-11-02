/* SPDX-License-Identifier: MIT */
#define LEPTON_NDK_UNIT_TEST
#include "ndk_auxv.c"
#include <assert.h>
#include <stdio.h>

static int clock_failure;
int clock_gettime(int clock, void *value) {
    assert(clock == 1);
    struct lepton_timespec *ts = value;
    ts->sec = 123;
    ts->nsec = 456;
    return clock_failure;
}
int main(void) {
    unsigned long regs[32] = {0}, pc = 100;
    assert(emulate_register(0xd5380000, regs, &pc) == 1);
    assert(regs[0] == 0x410fd030 && pc == 104);
    assert(emulate_register(0xd53be005, regs, &pc) == 1);
    assert(regs[5] == 1000000000UL && pc == 108);
    assert(emulate_register(0xd53be05e, regs, &pc) == 1);
    assert(regs[30] == 123000000456UL && pc == 112);
    regs[31] = 77;
    assert(emulate_register(0xd53be01f, regs, &pc) == 1);
    assert(regs[31] == 77 && pc == 116);
    assert(emulate_register(0xd503201f, regs, &pc) == 0); /* NOP */
    assert(emulate_register(0xd5380400, regs, &pc) == 0); /* Unhandled MRS */
    assert(pc == 116);
    clock_failure = -1;
    regs[2] = 42;
    assert(emulate_register(0xd53be042, regs, &pc) == -1);
    assert(regs[2] == 42 && pc == 116);
    puts("PASS: register values, destinations, XZR, PC, unknown opcodes and clock failures");
}

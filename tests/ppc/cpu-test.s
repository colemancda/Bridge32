# Guest code for tests/ppc/cpu-test.cpp, as the 32-bit PowerPC Mac's ABI runs
# it. Assembled by tools/ppc-asm.py into cpu-test-code.h; registers are
# numbers (r3 is 3, f1 is 1, v1 is 1) because that is what the assembler reads.
#
# Thunk stubs are at 0xF0000000, eight bytes apart, and too far for bl, so
# they're called the way a real binary's symbol stubs do: through ctr.
        .text

# store(p, v): *p = v
store:
        stw 4, 0(3)
        blr

# load(p): returns *p
load:
        lwz 3, 0(3)
        blr

# sum10(a0..a9): the first eight arguments are r3-r10, the ninth and tenth
# are at 56(r1) and 60(r1), after the linkage area and eight words of space.
sum10:
        add 3, 3, 4
        add 3, 3, 5
        add 3, 3, 6
        add 3, 3, 7
        add 3, 3, 8
        add 3, 3, 9
        add 3, 3, 10
        lwz 11, 56(1)
        add 3, 3, 11
        lwz 11, 60(1)
        add 3, 3, 11
        blr

# ret64(): 0x0123456789ABCDEF, high word in r3
ret64:
        lis 3, 0x0123
        ori 3, 3, 0x4567
        lis 4, 0x89AB
        ori 4, 4, 0xCDEF
        blr

# retdbl(p): returns *(double *)p in f1
retdbl:
        lfd 1, 0(3)
        blr

# fpu(p): p[2] = p[0] + p[1]; p[3] = p[0] * p[1] (doubles)
fpu:
        lfd 1, 0(3)
        lfd 2, 8(3)
        fadd 3, 1, 2
        stfd 3, 16(3)
        fmul 4, 1, 2
        stfd 4, 24(3)
        blr

# vec(p): the four floats at p+32 = the four at p plus the four at p+16
vec:
        addi 4, 3, 16
        addi 5, 3, 32
        lvx 1, 0, 3
        lvx 2, 0, 4
        vaddfp 3, 1, 2
        stvx 3, 0, 5
        blr

# bits(x): r4 = count of leading zeros, r5 = (x << 8) & 0xFF00 by rotate and
# insert, r6 = the condition register after comparing x with zero and a
# round trip through mtcrf, r7 = x byte-reversed by lwbrx from the stack
bits:
        cntlzw 4, 3
        li 5, 0
        rlwimi 5, 3, 8, 16, 23
        cmpwi 3, 0
        mfcr 6
        mtcrf 255, 6
        mfcr 6
        stw 3, -16(1)
        addi 8, 1, -16
        li 9, 0
        lwbrx 7, 9, 8
        blr

# tb(): the time base's low word
tb:
        mftb 3
        blr

# tbhi(): the time base's high word
tbhi:
        mftbu 3
        blr

# incr(p, n): n times, atomically *p += 1
incr:
        mtctr 4
1:      lwarx 5, 0, 3
        addi 5, 5, 1
        stwcx. 5, 0, 3
        bne- 1b
        bdnz 1b
        blr

# fault(): stores to an unmapped address; the handler skips the store. Returns
# 7 only if r3 survived the fault.
fault:
        li 3, 2
        lis 4, 0x7000
        stw 3, 0(4)
        addi 3, 3, 5
        blr

# handler(sig, info, ucontext), the SIGSEGV handler: records the signal, the
# address and the data storage status at 0x20000, and moves the saved PC
# past the store.
handler:
        lis 9, 0x0002
        stw 3, 0(9)
        lwz 6, 24(4)
        stw 6, 4(9)
        lwz 6, 28(5)
        lwz 7, 4(6)
        stw 7, 8(9)
        lwz 7, 32(6)
        addi 7, 7, 4
        stw 7, 32(6)
        blr

# callthunk(): thunk 0 with the nine arguments 1 to 9; the ninth is on the stack
callthunk:
        mflr 0
        stw 0, 8(1)
        stwu 1, -80(1)
        li 3, 1
        li 4, 2
        li 5, 3
        li 6, 4
        li 7, 5
        li 8, 6
        li 9, 7
        li 10, 8
        li 11, 9
        stw 11, 56(1)
        lis 12, 0xF000
        mtctr 12
        bctrl
call_return:
        addi 1, 1, 80
        lwz 0, 8(1)
        mtlr 0
        blr

# twice(x): returns x * 2
twice:
        add 3, 3, 3
        blr

# viathunk(): thunk 1, which calls twice(21) back in the guest, adding 1
viathunk:
        mflr 0
        stw 0, 8(1)
        stwu 1, -64(1)
        bl 1f
1:      mflr 3
        addi 3, 3, twice - 1b
        li 4, 21
        lis 12, 0xF000
        ori 12, 12, 8
        mtctr 12
        bctrl
        addi 1, 1, 64
        lwz 0, 8(1)
        mtlr 0
        blr

# outer() calls inner(), which calls thunk 2: the thunk sees both frames
outer:
        mflr 0
        stw 0, 8(1)
        stwu 1, -64(1)
        bl inner
outer_return:
        addi 1, 1, 64
        lwz 0, 8(1)
        mtlr 0
        blr
inner:
        mflr 0
        stw 0, 8(1)
        stwu 1, -64(1)
        lis 12, 0xF000
        ori 12, 12, 16
        mtctr 12
        bctrl
inner_return:
        addi 1, 1, 64
        lwz 0, 8(1)
        mtlr 0
        blr

# floats(): thunks 3 and 4 return 2.5 (a double) and 1.25 (a float) in f1,
# which are stored at 0x20010 and 0x20018
floats:
        mflr 0
        stw 0, 8(1)
        stwu 1, -64(1)
        lis 12, 0xF000
        ori 12, 12, 24
        mtctr 12
        bctrl
        lis 9, 0x0002
        stfd 1, 16(9)
        lis 12, 0xF000
        ori 12, 12, 32
        mtctr 12
        bctrl
        lis 9, 0x0002
        stfd 1, 24(9)
        addi 1, 1, 64
        lwz 0, 8(1)
        mtlr 0
        blr

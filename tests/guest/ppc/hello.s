# A PowerPC Mac program, in the Darwin ABI, calling libSystem through the
# bridge: the same checks as the other guests' hello, plus what is PowerPC's
# own. Linked by tools/ppc-link.py, which gives each import a stub and a lazy
# pointer as Mac OS X 10.4's ld did.
#
#  - the first eight argument words are r3-r10, and a 64-bit value takes two of
#    them, high word first (printf's %lld)
#  - a variadic call shadows a double in the words after it, as well as f1
#    (printf's %f), but a call with a fixed prototype passes it in f1 alone
#    (pow's two doubles in f1 and f2), and gets one back in f1
#
# crt1's `start` is entered with r1 pointing at argc.
        .text
        .globl start
start:
        mr 30, 1
        stwu 1, -96(1)

        lis 3, str_hello@ha
        addi 3, 3, str_hello@l
        lwz 4, 0(30)
        bl _printf

        lis 3, str_ll@ha
        addi 3, 3, str_ll@l
        lis 4, 0x0123
        ori 4, 4, 0x4567
        lis 5, 0x89AB
        ori 5, 5, 0xCDEF
        lis 6, 0xCAFE
        ori 6, 6, 0xF00D
        bl _printf

        lis 9, dbl_pi@ha
        addi 9, 9, dbl_pi@l
        lfd 1, 0(9)
        lwz 4, 0(9)
        lwz 5, 4(9)
        lis 3, str_dbl@ha
        addi 3, 3, str_dbl@l
        bl _printf

        lis 9, dbl_two@ha
        addi 9, 9, dbl_two@l
        lfd 1, 0(9)
        lis 9, dbl_ten@ha
        addi 9, 9, dbl_ten@l
        lfd 2, 0(9)
        bl _pow
        stfd 1, 64(1)
        lwz 4, 64(1)
        lwz 5, 68(1)
        lis 3, str_pow@ha
        addi 3, 3, str_pow@l
        bl _printf

        lis 3, str_word@ha
        addi 3, 3, str_word@l
        bl _strlen
        mr 4, 3
        lis 3, str_len@ha
        addi 3, 3, str_len@l
        bl _printf

        lis 3, str_done@ha
        addi 3, 3, str_done@l
        bl _puts

        li 3, 0
        bl _exit

        .data
str_hello:
        .asciz "hello from ppc, argc=%d\n"
str_ll:
        .asciz "long long=%lld hex=%08x\n"
str_dbl:
        .asciz "double=%.3f\n"
str_pow:
        .asciz "pow=%.1f\n"
str_word:
        .asciz "hello"
str_len:
        .asciz "strlen=%d\n"
str_done:
        .asciz "ppc hello passed"
        .balign 8
dbl_pi:
        .double 3.14159
dbl_two:
        .double 2.0
dbl_ten:
        .double 10.0

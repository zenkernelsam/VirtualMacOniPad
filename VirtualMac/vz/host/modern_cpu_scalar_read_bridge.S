// x0=bounded private holder, w1=scalar ID, x2=16-byte output wire,
// x3=authenticated function pointer to pinned original27 helper3810.
.text
.p2align 2
.globl _VZ27ScalarReadInvoke
_VZ27ScalarReadInvoke:
    cmp w1, #34
    b.eq Lreject_cpsr
    pacibsp
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x8, x2
    blraaz x3
    ldp x29, x30, [sp], #16
    retab
Lreject_cpsr:
    ret

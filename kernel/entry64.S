/* 64-bit kernel entry.
 *
 * Reached from the Multiboot stub after it enters long mode. Everything the C
 * code assumes about the machine is established here: zeroed BSS, a usable
 * FPU, and a stack. */

.section .text.entry, "ax"
.code64
.global _start64
_start64:
    /* The boot stub passes the bootloader's information structure in rdi. Save
     * it before anything else can use the register; kernel/memory.c reads the
     * memory size from it. */
    mov %rdi, boot_info_pointer(%rip)

    /* The bootloader zeroes nothing above 2MB. */
    mov $__bss64_start, %rdi
    mov $__bss64_end, %rcx
    sub %rdi, %rcx
    shr $3, %rcx
    xor %rax, %rax
    rep stosq

    /* The boot stub already enabled SSE, but do it again here so this entry
     * point does not depend on which path reached it. */
    mov %cr4, %rax
    or $(1 << 9 | 1 << 10), %rax
    mov %rax, %cr4

    mov %cr0, %rax
    and $~(1 << 2), %rax
    or $(1 << 1), %rax
    mov %rax, %cr0

    /* Firmware leaves the FPU control and rounding state unspecified. CRuby
     * reaches libm early, so put both in a known state. */
    fninit
    ldmxcsr default_mxcsr(%rip)
    fldcw default_fcw(%rip)

    mov $stack64_top, %rsp

    call kernel_main

1:  cli
    hlt
    jmp 1b

.section .data
.balign 8
.global boot_info_pointer
boot_info_pointer:
    .quad 0

.section .rodata
.balign 4
default_mxcsr:
    .long 0x1f80      /* all exceptions masked, round to nearest */
.balign 2
default_fcw:
    .word 0x037f      /* extended precision, round to nearest */

/* 8MB, matching the stack size patched into CRuby's thread setup. */
.section .bss
.align 16
.global stack64_bottom
stack64_bottom:
    .skip 8388608
stack64_top:

/* Multiboot entry: 32-bit, enters long mode, hands over to the 64-bit kernel.
 *
 * A Multiboot bootloader (or QEMU's -kernel) starts the machine in 32-bit
 * protected mode with paging off, but the kernel is 64-bit. The two cannot
 * live in one ELF comfortably, so the 64-bit kernel is built separately, and
 * its raw binary is embedded here at 2MB by the linker script. This stub sets
 * up just enough paging to enter long mode and jumps to it.
 */

.set MULTIBOOT_MAGIC,    0x1BADB002
.set MULTIBOOT_FLAGS,    0x00000003   /* align modules, provide memory map */
.set MULTIBOOT_CHECKSUM, -(MULTIBOOT_MAGIC + MULTIBOOT_FLAGS)

.section .multiboot, "a"
.align 4
    .long MULTIBOOT_MAGIC
    .long MULTIBOOT_FLAGS
    .long MULTIBOOT_CHECKSUM

.section .bss
.align 16
stack_bottom:
    .skip 16384
stack_top:

/* One PML4, one PDPT and one PD is enough: 512 entries of 2MB covers 1GB,
 * and only the first 512MB is mapped below. */
.align 4096
pml4:    .skip 4096
pdpt:    .skip 4096
pd:      .skip 4096

.section .rodata
.align 16
gdt64:
    .quad 0x0000000000000000    /* null */
    .quad 0x00AF9A000000FFFF    /* 64-bit code */
    .quad 0x00CF92000000FFFF    /* data */
gdt64_end:
gdt64_ptr:
    .word gdt64_end - gdt64 - 1
    .long gdt64

.section .text.boot, "ax"
.code32
.global _start
_start:
    cli
    mov $stack_top, %esp

    /* The bootloader does not zero BSS. */
    mov $__bss_start, %edi
    mov $__bss_end, %ecx
    sub %edi, %ecx
    shr $2, %ecx
    xor %eax, %eax
    rep stosl

    /* Identity map the low 512MB with 2MB pages. Identity mapping keeps
     * physical and virtual addresses equal, which is what lets the kernel
     * hand raw addresses to Ruby and back without translating anything. */
    mov $pdpt, %eax
    or $0x03, %eax              /* present | writable */
    mov %eax, (pml4)

    mov $pd, %eax
    or $0x03, %eax
    mov %eax, (pdpt)

    mov $pd, %edi
    mov $0x83, %eax             /* present | writable | page size (2MB) */
    xor %edx, %edx
    mov $256, %ecx
1:  mov %eax, (%edi)
    mov %edx, 4(%edi)
    add $0x200000, %eax
    adc $0, %edx
    add $8, %edi
    dec %ecx
    jnz 1b

    /* PAE, plus OSFXSR and OSXMMEXCPT so SSE is usable. CRuby's floating
     * point paths need it and fault immediately without it. */
    mov %cr4, %eax
    or $(1 << 5 | 1 << 9 | 1 << 10), %eax
    mov %eax, %cr4

    /* Clear EM, set MP: use the FPU rather than trapping on it. */
    mov %cr0, %eax
    and $~(1 << 2), %eax
    or $(1 << 1), %eax
    mov %eax, %cr0

    mov $pml4, %eax
    mov %eax, %cr3

    /* IA32_EFER.LME */
    mov $0xC0000080, %ecx
    rdmsr
    or $(1 << 8), %eax
    wrmsr

    /* Paging on; long mode becomes active here. */
    mov %cr0, %eax
    or $0x80000001, %eax
    mov %eax, %cr0

    lgdt (gdt64_ptr)
    ljmp $0x08, $long_mode_entry

.code64
long_mode_entry:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    mov $0x200000, %rax
    jmp *%rax

1:  cli
    hlt
    jmp 1b

/* The 64-bit kernel image, placed at 2MB by the linker script. The build
 * passes -I for the directory holding it, so the assembler resolves the name
 * through its include path. */
.section .kernel64, "a"
.incbin "kernel64.bin"

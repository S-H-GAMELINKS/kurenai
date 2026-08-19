/* Exception handling, for the sake of being told what went wrong.
 *
 * Without an IDT a fault triple-faults and the machine resets, and a null
 * dereference does not even do that: the boot stub identity maps from zero, so
 * reading through a null pointer returns zeros and the caller carries on into
 * a loop. Two problems in this project have presented as "the kernel hangs"
 * for exactly that reason.
 *
 * So: install handlers that print where and why, and unmap the first page so
 * that dereferencing null is a fault rather than a source of zeros. */

#include <stdint.h>

#include "kernel.h"

#define IDT_ENTRIES 256
#define KERNEL_CODE_SELECTOR 0x08
#define GATE_INTERRUPT 0x8E   /* present, ring 0, interrupt gate */

struct idt_entry {
    uint16_t offset_low;
    uint16_t selector;
    uint8_t  ist;
    uint8_t  type_attr;
    uint16_t offset_mid;
    uint32_t offset_high;
    uint32_t reserved;
} __attribute__((packed));

struct idt_pointer {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));

/* The layout isr.S builds on the stack, innermost first. */
struct fault_frame {
    uint64_t r15, r14, r13, r12, r11, r10, r9, r8;
    uint64_t rbp, rdi, rsi, rdx, rcx, rbx, rax;
    uint64_t vector;
    uint64_t error_code;
    uint64_t rip;
    uint64_t cs;
    uint64_t rflags;
    uint64_t rsp;
    uint64_t ss;
};

static struct idt_entry idt[IDT_ENTRIES];

/* Defined in isr.S, one per vector. */
extern void isr_0(void);
#define ISR(n) extern void isr_##n(void);
ISR(1) ISR(2) ISR(3) ISR(4) ISR(5) ISR(6) ISR(7) ISR(8) ISR(9) ISR(10)
ISR(11) ISR(12) ISR(13) ISR(14) ISR(15) ISR(16) ISR(17) ISR(18) ISR(19)
ISR(20) ISR(21) ISR(22) ISR(23) ISR(24) ISR(25) ISR(26) ISR(27) ISR(28)
ISR(29) ISR(30) ISR(31)
#undef ISR

static void (*const handlers[32])(void) = {
    isr_0,  isr_1,  isr_2,  isr_3,  isr_4,  isr_5,  isr_6,  isr_7,
    isr_8,  isr_9,  isr_10, isr_11, isr_12, isr_13, isr_14, isr_15,
    isr_16, isr_17, isr_18, isr_19, isr_20, isr_21, isr_22, isr_23,
    isr_24, isr_25, isr_26, isr_27, isr_28, isr_29, isr_30, isr_31,
};

static const char *const names[32] = {
    "divide error", "debug", "NMI", "breakpoint",
    "overflow", "bound range exceeded", "invalid opcode", "device not available",
    "double fault", "coprocessor segment overrun", "invalid TSS", "segment not present",
    "stack fault", "general protection fault", "page fault", "reserved",
    "x87 floating point", "alignment check", "machine check", "SIMD floating point",
    "virtualization", "control protection", "reserved", "reserved",
    "reserved", "reserved", "reserved", "reserved",
    "hypervisor injection", "VMM communication", "security exception", "reserved",
};

static void
set_gate(int vector, void (*handler)(void))
{
    uint64_t address = (uint64_t)(uintptr_t)handler;

    idt[vector].offset_low  = (uint16_t)(address & 0xFFFF);
    idt[vector].selector    = KERNEL_CODE_SELECTOR;
    idt[vector].ist         = 0;
    idt[vector].type_attr   = GATE_INTERRUPT;
    idt[vector].offset_mid  = (uint16_t)((address >> 16) & 0xFFFF);
    idt[vector].offset_high = (uint32_t)(address >> 32);
    idt[vector].reserved    = 0;
}

static void
put_hex(uint64_t value)
{
    static const char digits[] = "0123456789abcdef";
    serial_puts("0x");
    int started = 0;
    for (int shift = 60; shift >= 0; shift -= 4) {
        int nibble = (int)((value >> shift) & 0xF);
        if (nibble || started || shift == 0) {
            serial_putc(digits[nibble]);
            started = 1;
        }
    }
}

/* Called from isr.S with the stack frame it built. */
void
fault_report(struct fault_frame *frame)
{
    uint64_t cr2;
    __asm__ volatile ("mov %%cr2, %0" : "=r"(cr2));

    serial_puts("\n--- fault: ");
    serial_puts(frame->vector < 32 ? names[frame->vector] : "unknown");
    serial_puts(" (vector ");
    put_hex(frame->vector);
    serial_puts(", error ");
    put_hex(frame->error_code);
    serial_puts(")\n");

    serial_puts("  rip ");   put_hex(frame->rip);
    serial_puts("  rsp ");   put_hex(frame->rsp);
    serial_puts("  rflags "); put_hex(frame->rflags);
    serial_putc('\n');

    if (frame->vector == 14) {
        /* The faulting address is the whole story for a page fault, and a null
         * one names the bug outright. */
        serial_puts("  address ");
        put_hex(cr2);
        if (cr2 < 0x1000) serial_puts("  (null dereference)");
        serial_putc('\n');
    }

    serial_puts("  rax "); put_hex(frame->rax);
    serial_puts("  rbx "); put_hex(frame->rbx);
    serial_puts("  rcx "); put_hex(frame->rcx);
    serial_puts("  rdx "); put_hex(frame->rdx);
    serial_putc('\n');
    serial_puts("  rsi "); put_hex(frame->rsi);
    serial_puts("  rdi "); put_hex(frame->rdi);
    serial_puts("  rbp "); put_hex(frame->rbp);
    serial_putc('\n');

    /* A crude backtrace: scan the stack for values that land inside the
     * kernel's text and print them. Compiled without frame pointers there is
     * no chain to walk, and this finds the return addresses anyway, along with
     * some noise. Resolve them with llvm-nm against kernel64.elf. */
    extern char _etext_marker[] __asm__("etext");
    uintptr_t text_start = 0x200000;
    uintptr_t text_end = (uintptr_t)_etext_marker;
    const uint64_t *stack = (const uint64_t *)(uintptr_t)frame->rsp;

    serial_puts("  stack:");
    int printed = 0;
    for (int i = 0; i < 128 && printed < 12; i++) {
        uint64_t value = stack[i];
        if (value >= text_start && value < text_end) {
            serial_puts(" ");
            put_hex(value);
            printed++;
        }
    }
    serial_putc('\n');

    serial_puts("--- halted\n");
}

void
idt_init(void)
{
    for (int vector = 0; vector < 32; vector++)
        set_gate(vector, handlers[vector]);

    struct idt_pointer pointer = {
        .limit = sizeof(idt) - 1,
        .base = (uint64_t)(uintptr_t)idt,
    };
    __asm__ volatile ("lidt %0" : : "m"(pointer));
}

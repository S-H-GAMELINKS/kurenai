/* A clock that interrupts.
 *
 * Until now the kernel had no interrupt source at all: the TSC tells the time
 * when asked, the network card is polled, and the serial port is polled. That
 * was enough for one thread. It is not enough for two, because a thread that
 * never makes a syscall would never give the CPU back -- so the PIT's channel
 * 0 is set ticking at 1kHz, through the legacy 8259 PIC.
 *
 * The tick arrives on its own stack. Everything here runs in ring 0, where an
 * interrupt does not switch stacks by itself: the CPU pushes its frame just
 * below the interrupted rsp, which is inside the 128-byte red zone the SysV
 * ABI lets leaf functions use without moving rsp. Most of the image could be
 * rebuilt with -mno-red-zone, but not all of it -- compiler-rt's builtins come
 * prebuilt with clang -- so instead the tick's gate names an Interrupt Stack
 * Table entry, and the CPU switches to that stack before pushing anything. The
 * TSS exists only to hold that pointer. */

#include <stdint.h>

#include "kernel.h"

#define PIC1_COMMAND 0x20
#define PIC1_DATA    0x21
#define PIC2_COMMAND 0xA0
#define PIC2_DATA    0xA1
#define PIC_EOI      0x20

#define PIT_FREQUENCY_HZ 1193182u
#define PIT_CHANNEL0     0x40
#define PIT_COMMAND      0x43

#define TICK_HZ 1000u

/* ---------------------------------------------------------------- TSS */

struct tss64 {
    uint32_t reserved0;
    uint64_t rsp[3];
    uint64_t reserved1;
    uint64_t ist[7];
    uint64_t reserved2;
    uint16_t reserved3;
    uint16_t iomap_base;
} __attribute__((packed));

_Static_assert(sizeof(struct tss64) == 104, "the TSS is 104 bytes");

static struct tss64 tss;

static uint8_t tick_stack[16384] __attribute__((aligned(16)));

/* The boot stub's GDT, plus a TSS descriptor. The code and data descriptors
 * are the same values at the same selectors, so loading this table changes
 * nothing about the segments already in use and no reload is needed. A 64-bit
 * TSS descriptor is sixteen bytes and fills the last two slots. */
static uint64_t gdt[5] __attribute__((aligned(16))) = {
    0x0000000000000000,     /* null */
    0x00AF9A000000FFFF,     /* 0x08: 64-bit code */
    0x00CF92000000FFFF,     /* 0x10: data */
    0, 0,                   /* 0x18: TSS, filled in below */
};

#define TSS_SELECTOR 0x18

struct gdt_pointer {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));

static void
tss_init(void)
{
    tss.ist[0] = (uint64_t)(uintptr_t)(tick_stack + sizeof(tick_stack));
    tss.iomap_base = sizeof(tss);   /* no I/O permission bitmap */

    uint64_t base = (uint64_t)(uintptr_t)&tss;
    uint64_t limit = sizeof(tss) - 1;
    gdt[3] = (limit & 0xFFFF)
           | ((base & 0xFFFFFF) << 16)
           | (0x89ull << 40)                    /* present, available 64-bit TSS */
           | (((limit >> 16) & 0xF) << 48)
           | (((base >> 24) & 0xFF) << 56);
    gdt[4] = base >> 32;

    struct gdt_pointer pointer = {
        .limit = sizeof(gdt) - 1,
        .base = (uint64_t)(uintptr_t)gdt,
    };
    __asm__ volatile ("lgdt %0" : : "m"(pointer));
    __asm__ volatile ("ltr %w0" : : "r"((uint16_t)TSS_SELECTOR));
}

/* ---------------------------------------------------------------- PIC */

/* The PIC delivers IRQ0-7 on vectors 8-15 after reset, which are the CPU's
 * own exceptions: a tick would arrive as a double fault. Moving them to 0x20
 * and up is the first thing any PC kernel does with it. Everything except the
 * timer stays masked -- the card and the serial port are still polled. */
static void
pic_init(void)
{
    outb(PIC1_COMMAND, 0x11);   /* ICW1: initialise, ICW4 follows */
    outb(PIC2_COMMAND, 0x11);
    outb(PIC1_DATA, 0x20);      /* ICW2: IRQ0-7 at vector 0x20 */
    outb(PIC2_DATA, 0x28);      /*       IRQ8-15 at vector 0x28 */
    outb(PIC1_DATA, 0x04);      /* ICW3: the slave is on IRQ2 */
    outb(PIC2_DATA, 0x02);
    outb(PIC1_DATA, 0x01);      /* ICW4: 8086 mode */
    outb(PIC2_DATA, 0x01);

    outb(PIC1_DATA, 0xFE);      /* IRQ0 only */
    outb(PIC2_DATA, 0xFF);
}

/* ---------------------------------------------------------------- PIT */

static void
pit_init(void)
{
    uint16_t divisor = (uint16_t)(PIT_FREQUENCY_HZ / TICK_HZ);
    outb(PIT_COMMAND, 0x34);    /* channel 0, lo/hi byte, mode 2: rate generator */
    outb(PIT_CHANNEL0, (uint8_t)(divisor & 0xFF));
    outb(PIT_CHANNEL0, (uint8_t)(divisor >> 8));
}

/* ---------------------------------------------------------------- ticks */

/* Incremented by irq_tick in kernel/task.c, for every tick, and nowhere else. */
volatile uint64_t irq_ticks;

uint64_t
irq_tick_count(void)
{
    return irq_ticks;
}

void
irq_init(void)
{
    tss_init();
    pic_init();
    idt_set_interrupt(0x20, irq_timer, 1);
    pit_init();
    __asm__ volatile ("sti");

    /* Say so only once it is true: wait 20ms by the TSC and count what
     * arrived. A tick that is configured and never delivered would otherwise
     * look exactly like one that works until something waits on it. */
    uint64_t start = timer_millis();
    uint64_t before = irq_ticks;
    while (timer_millis() - start < 20)
        __asm__ volatile ("pause");
    uint64_t arrived = irq_ticks - before;

    serial_puts("irq: timer ");
    serial_put_uint(TICK_HZ);
    serial_puts(" Hz, ");
    serial_put_uint(arrived);
    serial_puts(" ticks in 20 ms\n");
}

/* Waits for the next interrupt. sti and hlt together, because sti takes effect
 * only after the following instruction: an interrupt cannot slip in between
 * and leave hlt waiting for one that has already been. It also means the wait
 * ends even if something cleared the flag -- mruby-task's critical sections
 * are cli/sti. */
void
irq_wait(void)
{
    __asm__ volatile ("sti; hlt");
}

#ifndef PICORUBY_KERNEL_H
#define PICORUBY_KERNEL_H

#include <stddef.h>
#include <stdint.h>

/* COM1. The only output device the kernel has at this point, and the one the
 * boot smoke test reads. */
void   serial_init(void);
void   serial_putc(char c);
void   serial_puts(const char *s);
void   serial_write(const char *buf, size_t len);
int    serial_data_ready(void);
int    serial_getc(void);
size_t serial_read(char *buf, size_t len);

/* Entry point called from entry64.S. */
void kernel_main(void);

/* Installs handlers for the CPU's exceptions, so a fault reports itself
 * instead of resetting the machine. */
void idt_init(void);
void idt_set_interrupt(int vector, void (*handler)(void), int ist);

/* The timer interrupt: PIT channel 0 at 1kHz through the 8259, delivered on an
 * IST stack so an interrupted function's red zone survives. irq_wait sleeps
 * until the next interrupt. */
void     irq_init(void);
void     irq_wait(void);
uint64_t irq_tick_count(void);
void     irq_timer(void);   /* the entry stub in isr.S */

/* Monotonic time since boot, from the TSC calibrated against the PIT. */
void     timer_init(void);
uint64_t timer_millis(void);
uint64_t timer_nanos(void);

/* Does what __libc_start_main would have: thread pointer, auxiliary vector. */
void libc_init(void);

/* What the machine says about memory. The pages themselves are handed out
 * and taken back by ruby/kernel/memory.rb. */
uintptr_t memory_image_end(void);
uintptr_t memory_boot_info(void);
uintptr_t memory_mapped_limit(void);

/* Decimal, for the few places the kernel has to print a number. */
void serial_put_uint(uint64_t value);

/* Port I/O. Here rather than in one .c file because the PIT, the PCI
 * configuration space and the Ruby side all need it, and because there is
 * nothing to it: these are single instructions with an ABI. */
static inline void outb(uint16_t port, uint8_t value)
{
    __asm__ volatile ("outb %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint8_t inb(uint16_t port)
{
    uint8_t value;
    __asm__ volatile ("inb %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

static inline void outl(uint16_t port, uint32_t value)
{
    __asm__ volatile ("outl %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint32_t inl(uint16_t port)
{
    uint32_t value;
    __asm__ volatile ("inl %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

/* The PicoRuby VM. It stays open for the life of the system, because the
 * syscall dispatcher runs in it. */
void vm_start(void);
struct mrb_state;
struct mrb_state *vm_state(void);
void vm_report_syscalls(void);

/* Starts CRuby and evaluates the userland script. */
void cruby_start(void);

/* Called by musl in place of the syscall instruction. bridge.c decides whether
 * a call goes to Ruby or stays in C; syscall.c is the C half. */
long kernel_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6);
long kernel_syscall_c(long n, long a1, long a2, long a3, long a4, long a5, long a6);

/* Sends one syscall number to Kernel::Syscall.dispatch from now on. */
void bridge_route(long number);

/* lwIP and the primitives the Ruby driver drives it through. Registered on the
 * same module as the rest, from bridge_init. */
struct RClass;
void net_init(struct mrb_state *mrb, struct RClass *module);

#endif /* PICORUBY_KERNEL_H */

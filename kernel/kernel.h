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

/* Monotonic time since boot, from the TSC calibrated against the PIT. */
void     timer_init(void);
uint64_t timer_millis(void);
uint64_t timer_nanos(void);

/* Does what __libc_start_main would have: thread pointer, auxiliary vector. */
void libc_init(void);

/* Pages handed out through mmap, taken from RAM above the kernel image. */
void   memory_init(void);
void  *memory_alloc_pages(size_t length);
uintptr_t memory_arena_start(void);
uintptr_t memory_arena_next(void);
size_t memory_used(void);
size_t memory_available(void);
void   serial_report_memory(void);

/* Decimal, for the few places the kernel has to print a number. */
void serial_put_uint(uint64_t value);

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

#endif /* PICORUBY_KERNEL_H */

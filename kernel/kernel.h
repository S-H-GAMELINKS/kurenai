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

/* Monotonic time since boot, from the TSC calibrated against the PIT. */
void     timer_init(void);
uint64_t timer_millis(void);
uint64_t timer_nanos(void);

/* Points musl's thread pointer at a usable block; errno depends on it. */
void tls_init(void);

/* Pages handed out through mmap, taken from RAM above the kernel image. */
void   memory_init(void);
void  *memory_alloc_pages(size_t length);
size_t memory_used(void);
size_t memory_available(void);

/* Starts the PicoRuby VM and runs the embedded boot script. */
void vm_start(void);

/* Starts CRuby and evaluates the userland script. */
void cruby_start(void);

/* Called by musl in place of the syscall instruction; see kernel/syscall.c. */
long kernel_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6);

#endif /* PICORUBY_KERNEL_H */

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

#endif /* PICORUBY_KERNEL_H */

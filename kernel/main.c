/* Kernel entry.
 *
 * The order here is the dependency order, and each line prints so that a
 * failure names the stage it happened in rather than showing up as silence.
 * TLS comes before anything that might touch errno, which is nearly the first
 * thing libc does. */

#include "kernel.h"

void
kernel_main(void)
{
    serial_init();
    serial_puts("boot ok\n");

    timer_init();
    serial_puts("timer ok\n");

    tls_init();
    serial_puts("tls ok\n");

    memory_init();
    serial_puts("memory ok\n");

    vm_start();

    cruby_start();

    serial_puts("kernel: done\n");
}

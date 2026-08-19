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
    if (!vm_state()) {
        serial_puts("kernel: the Ruby side did not come up\n");
        return;
    }

    /* From here on, writing to the console is Ruby's job. Routing is switched
     * on only once the VM is known good: if the dispatcher were unavailable,
     * every write would fail, including the ones reporting why. */
    bridge_route(1  /* SYS_write  */);
    bridge_route(20 /* SYS_writev */);   /* what musl's stdio actually uses */
    serial_puts("syscall routing ok\n");

    cruby_start();

    vm_report_syscalls();
    serial_puts("kernel: done\n");
}

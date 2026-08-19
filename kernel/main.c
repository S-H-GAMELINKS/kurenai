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

    /* First, so that everything after it can fail legibly. */
    idt_init();
    serial_puts("traps ok\n");

    timer_init();
    serial_puts("timer ok\n");

    libc_init();
    serial_puts("libc ok\n");

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
    /* The console and the filesystem are Ruby's from here on. What stays in C
     * is the machine: memory, time, the CPU. */
    bridge_route(1   /* SYS_write  */);
    bridge_route(20  /* SYS_writev */);  /* what musl's stdio actually uses */
    bridge_route(0   /* SYS_read   */);
    bridge_route(2   /* SYS_open   */);
    bridge_route(257 /* SYS_openat */);
    bridge_route(3   /* SYS_close  */);
    bridge_route(5   /* SYS_fstat  */);
    bridge_route(4   /* SYS_stat   */);
    bridge_route(6   /* SYS_lstat  */);
    bridge_route(262 /* SYS_newfstatat */);
    bridge_route(8   /* SYS_lseek  */);
    bridge_route(22  /* SYS_pipe   */);
    bridge_route(293 /* SYS_pipe2  */);
    serial_puts("syscall routing ok\n");

    cruby_start();

    vm_report_syscalls();
    serial_puts("kernel: done\n");
}

/* Kernel entry.
 *
 * The C here does as little as it can: bring up the console, then hand control
 * to Ruby. What the kernel does on boot is written in ruby/kernel/boot.rb. */

#include "kernel.h"

void
kernel_main(void)
{
    serial_init();
    serial_puts("boot ok\n");

    vm_start();

    serial_puts("kernel: boot.rb returned\n");
}

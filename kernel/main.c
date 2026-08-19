/* Kernel entry.
 *
 * At this milestone the kernel only proves the machine is in the state the
 * rest of the system will assume: long mode, identity-mapped memory, a working
 * console. The PicoRuby VM comes next. */

#include "kernel.h"

void
kernel_main(void)
{
    serial_init();
    serial_puts("boot ok\n");
}

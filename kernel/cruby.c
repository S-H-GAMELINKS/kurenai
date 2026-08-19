/* CRuby as the userland.
 *
 * CRuby runs in the same ring and the same address space as the kernel; what
 * makes it userland is that everything it asks for goes through the syscall
 * shim rather than being called directly. From CRuby's point of view it is an
 * ordinary Linux process whose kernel happens to be linked into it.
 *
 * The declarations are written out rather than included: ruby.h expects the
 * configuration of the host it was built for, and this file only needs five
 * entry points. */

#include "kernel.h"

void ruby_init_stack(volatile void *addr);
int  ruby_setup(void);
void ruby_script(const char *name);
int  rb_eval_string_protect(const char *str, int *state);

/* The userland script, embedded at build time. */
extern const char userland_script[];

void
cruby_start(void)
{
    /* CRuby scans the machine stack conservatively during garbage collection
     * and needs to know where it starts. A local in this frame is the highest
     * address it will ever have to look at. */
    volatile int stack_anchor = 0;
    ruby_init_stack(&stack_anchor);

    if (ruby_setup() != 0) {
        serial_puts("cruby: ruby_setup failed\n");
        return;
    }
    ruby_script("picoruby-kernel");
    serial_puts("cruby init ok\n");

    int state = 0;
    rb_eval_string_protect(userland_script, &state);
    if (state) {
        /* Printing the exception needs more of CRuby than has been proven to
         * work here, so report the fact and leave the detail for later. */
        serial_puts("cruby: exception while evaluating the userland script\n");
    }
}

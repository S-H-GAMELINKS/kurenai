/* Platform contract for the PicoRuby VM.
 *
 * libmruby.a leaves a small set of symbols undefined and expects the platform
 * to supply them. verify_picoruby_symbols pins that set, so if this file and
 * the library ever disagree, the test says so before the link does. */

#include <mruby.h>
/* mruby-task's HAL contract, including mrb_tick which the platform is expected
 * to call. Not reachable through mruby.h. */
#include <task_hal.h>

#include "kernel.h"

/* ---------------------------------------------------------------- scheduler
 *
 * mruby-task drives cooperative multitasking from a periodic tick. There is no
 * timer yet, so the scheduler is advanced by hand from the idle and sleep
 * paths. Nothing in the kernel creates tasks at this point, which is why that
 * is good enough; a TSC-backed tick replaces it later. */

void
mrb_hal_task_init(mrb_state *mrb)
{
    (void)mrb;
}

void
mrb_hal_task_final(mrb_state *mrb)
{
    (void)mrb;
}

void
mrb_hal_task_idle_cpu(mrb_state *mrb)
{
    /* Not hlt: with no interrupt source, halting here would never return. */
    mrb_tick(mrb);
    __asm__ volatile ("pause");
}

void
mrb_hal_task_sleep_us(mrb_state *mrb, mrb_int usec)
{
    /* Busy-wait, and deliberately not calibrated. Wall-clock sleeping needs
     * the timer; until then this only has to keep the scheduler moving. */
    for (mrb_int i = 0; i < usec; i++) {
        mrb_tick(mrb);
        __asm__ volatile ("pause");
    }
}

/* The scheduler's critical sections. Interrupts are the thing to keep out once
 * a timer exists; cli/sti is exactly that, and harmless before then. */

void
mrb_task_enable_irq(void)
{
    __asm__ volatile ("sti");
}

void
mrb_task_disable_irq(void)
{
    __asm__ volatile ("cli");
}

/* ---------------------------------------------------------------- stubs
 *
 * Two symbols libmruby.a references but this configuration never reaches. */

/* NOTE:
 * libmruby.a also leaves pm_constant_pool_id_to_constant undefined, from
 * mruby-compiler2, which is not linked: the kernel runs precompiled bytecode
 * and has no Ruby source for the mruby side to parse. No stub is defined for
 * it here, because CRuby brings Prism and defines the real one; adding a stub
 * as well is a duplicate symbol at link time. The reference from libmruby.a
 * resolves to Prism's and is never taken.
 */

/* mruby-io's file_ext.c references this. The kernel routes IO through its own
 * console rather than file descriptors the VM knows about. */
int
mrb_io_fileno(mrb_state *mrb, mrb_value io)
{
    (void)mrb;
    (void)io;
    return -1;
}

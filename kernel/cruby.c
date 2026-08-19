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

typedef unsigned long VALUE;
typedef unsigned long ID;

void  ruby_init_stack(volatile void *addr);
int   ruby_setup(void);

/* Normally reached through ruby_options, which parses a command line and then
 * finishes initialisation. There is no command line here, so the parts that
 * matter are called directly. Without them CRuby starts and runs ordinary
 * code, which is what made their absence easy to miss:
 *
 *   Init_ext                registers the statically linked extensions, so
 *                           require "io/console" and require "ripper" resolve
 *   rb_call_builtin_inits   installs the builtin function tables, without
 *                           which every Primitive-backed method in the prelude
 *                           misbehaves -- Kernel#loop, #class, #tap, #then,
 *                           #frozen?, Integer(), Float()
 *   Init_builtin_features   loads the builtin Ruby itself
 */
void  Init_ext(void);
void  Init_extra_exts(void);
void  rb_call_builtin_inits(void);
void  Init_builtin_features(void);
void  ruby_script(const char *name);
int   rb_eval_string_protect(const char *str, int *state);
VALUE rb_errinfo(void);
void  rb_set_errinfo(VALUE err);
ID    rb_intern(const char *name);
VALUE rb_funcall(VALUE recv, ID mid, int argc, ...);
char *rb_string_value_cstr(volatile VALUE *ptr);

/* Reports why the script failed. Worth the extra CRuby surface: without it a
 * failure is indistinguishable from any other, and the whole point of running
 * Ruby here is to be told what went wrong. */
static void
report_exception(void)
{
    VALUE err = rb_errinfo();
    rb_set_errinfo(0 /* Qnil */);

    serial_puts("cruby: ");
    VALUE klass = rb_funcall(err, rb_intern("class"), 0);
    VALUE name = rb_funcall(klass, rb_intern("to_s"), 0);
    serial_puts(rb_string_value_cstr(&name));
    serial_puts(": ");
    VALUE message = rb_funcall(err, rb_intern("message"), 0);
    serial_puts(rb_string_value_cstr(&message));
    serial_putc('\n');
}

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
    Init_ext();
    Init_extra_exts();
    rb_call_builtin_inits();
    Init_builtin_features();

    ruby_script("picoruby-kernel");


    serial_puts("cruby init ok\n");

    int state = 0;
    rb_eval_string_protect(userland_script, &state);
    if (state) report_exception();
}

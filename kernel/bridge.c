/* The boundary between CRuby and the Ruby kernel.
 *
 * musl calls kernel_syscall for everything. Numbers in the routing table go to
 * Kernel::Syscall.dispatch in the PicoRuby VM; the rest stay in C. The table
 * is a bitmap so syscalls can be moved across one at a time, which also means
 * a regression can be bisected by moving one back.
 *
 * Three rules hold this together, and all three are load-bearing:
 *
 *   Re-entrancy. Anything the dispatcher does that reaches libc would come
 *   back through kernel_syscall. The guard sends that back to the C path
 *   instead of recursing into a VM that is already running.
 *
 *   The GC arena. Values created while servicing a call are dead as soon as it
 *   returns; without saving and restoring the arena they accumulate for the
 *   lifetime of the system.
 *
 *   Exceptions. There is nothing above this frame to catch one. An exception
 *   that escapes has to be turned back into an errno, or it unwinds into
 *   CRuby, which has no idea the VM exists. */

#include <errno.h>
#include <stdint.h>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include "kernel.h"

/* Room for every Linux syscall number in use. */
#define ROUTE_WORDS 8
static uint64_t routed[ROUTE_WORDS];

static int in_dispatch;
static struct RClass *syscall_module;

void
bridge_route(long number)
{
    if (number < 0 || number >= ROUTE_WORDS * 64) return;
    routed[number / 64] |= (uint64_t)1 << (number % 64);
}

static int
is_routed(long number)
{
    if (number < 0 || number >= ROUTE_WORDS * 64) return 0;
    return (routed[number / 64] >> (number % 64)) & 1;
}

/* ---------------------------------------------------------------- primitives
 *
 * What the Ruby side is allowed to do. Everything the dispatcher needs that
 * cannot be expressed in Ruby lives here, and nothing more: this is the whole
 * surface between the kernel's Ruby and the machine. */

static mrb_value
prim_serial_write(mrb_state *mrb, mrb_value self)
{
    mrb_int address, count;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &count);
    if (count > 0) serial_write((const char *)(uintptr_t)address, (size_t)count);
    return mrb_nil_value();
}

static mrb_value
prim_serial_read(mrb_state *mrb, mrb_value self)
{
    mrb_int address, count;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &count);
    if (count <= 0) return mrb_int_value(mrb, 0);
    size_t n = serial_read((char *)(uintptr_t)address, (size_t)count);
    return mrb_int_value(mrb, (mrb_int)n);
}

/* Moves bytes between two places the Ruby side only knows as addresses: out of
 * the image and into a caller's buffer. Ruby decides the ranges, C moves them,
 * and nothing becomes a Ruby object on the way. */
static mrb_value
prim_copy_out(mrb_state *mrb, mrb_value self)
{
    mrb_int dest, src, length;
    (void)self;

    mrb_get_args(mrb, "iii", &dest, &src, &length);
    if (length > 0)
        __builtin_memcpy((void *)(uintptr_t)dest, (const void *)(uintptr_t)src,
                         (size_t)length);
    return mrb_nil_value();
}

static mrb_value
prim_memzero(mrb_state *mrb, mrb_value self)
{
    mrb_int address, length;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &length);
    if (length > 0)
        __builtin_memset((void *)(uintptr_t)address, 0, (size_t)length);
    return mrb_nil_value();
}

/* Reads a NUL-terminated string out of the caller's memory. This one does
 * create a Ruby object, and has to: a path is something the Ruby kernel
 * compares and looks up, not a range it forwards. The bytes are copied, so the
 * result belongs to the VM that made it. */
static mrb_value
prim_cstring(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    (void)self;

    mrb_get_args(mrb, "i", &address);
    if (address == 0) return mrb_str_new_lit(mrb, "");

    const char *p = (const char *)(uintptr_t)address;
    size_t len = 0;
    while (len < 4096 && p[len]) len++;
    return mrb_str_new(mrb, p, len);
}

/* The table the linker built, handed over once at boot. Each entry is
 * [path, address, size]; ruby/kernel/vfs.rb turns it into a lookup. */
struct embedded_file {
    const char          *path;
    const unsigned char *data;
    size_t               size;
};
extern const struct embedded_file embedded_files[];
extern const size_t embedded_file_count;

static mrb_value
prim_embedded_files(mrb_state *mrb, mrb_value self)
{
    (void)self;

    mrb_value list = mrb_ary_new_capa(mrb, (mrb_int)embedded_file_count);
    for (size_t i = 0; i < embedded_file_count; i++) {
        mrb_value entry = mrb_ary_new_capa(mrb, 3);
        mrb_ary_push(mrb, entry, mrb_str_new_cstr(mrb, embedded_files[i].path));
        mrb_ary_push(mrb, entry,
                     mrb_int_value(mrb, (mrb_int)(uintptr_t)embedded_files[i].data));
        mrb_ary_push(mrb, entry, mrb_int_value(mrb, (mrb_int)embedded_files[i].size));
        mrb_ary_push(mrb, list, entry);
    }
    return list;
}

static mrb_value
prim_peek32(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    (void)self;

    mrb_get_args(mrb, "i", &address);
    return mrb_int_value(mrb, (mrb_int)*(uint32_t *)(uintptr_t)address);
}

static mrb_value
prim_poke16(mrb_state *mrb, mrb_value self)
{
    mrb_int address, value;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &value);
    *(uint16_t *)(uintptr_t)address = (uint16_t)value;
    return mrb_nil_value();
}

/* Has a byte arrived? Asked by the poll implementation and by the raw-mode
 * read, both of which have to decide whether to wait without committing to it. */
static mrb_value
prim_serial_ready(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    return serial_data_ready() ? mrb_true_value() : mrb_false_value();
}

/* Reads only what has already arrived, unlike serial_read, which blocks for
 * the first byte. Raw mode needs the distinction. */
static mrb_value
prim_serial_read_ready(mrb_state *mrb, mrb_value self)
{
    mrb_int address, count;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &count);

    char *out = (char *)(uintptr_t)address;
    mrb_int n = 0;
    while (n < count && serial_data_ready())
        out[n++] = (char)serial_getc();
    return mrb_int_value(mrb, n);
}

/* Lets the CPU rest between polls. Without it a wait is a tight loop, which
 * costs nothing here but says the wrong thing about what the kernel is doing. */
static mrb_value
prim_idle(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    __asm__ volatile ("pause");
    return mrb_nil_value();
}

static mrb_value
prim_poke32(mrb_state *mrb, mrb_value self)
{
    mrb_int address, value;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &value);
    *(uint32_t *)(uintptr_t)address = (uint32_t)value;
    return mrb_nil_value();
}

/* Copies bytes out of the caller's memory into a Ruby Array of integers. Used
 * for pipe writes, where the kernel has to keep the bytes rather than forward
 * them, so they must become objects the Ruby side owns. */
static mrb_value
prim_read_bytes(mrb_state *mrb, mrb_value self)
{
    mrb_int address, length;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &length);
    if (length < 0) length = 0;

    const unsigned char *p = (const unsigned char *)(uintptr_t)address;
    mrb_value list = mrb_ary_new_capa(mrb, (mrb_int)length);
    for (mrb_int i = 0; i < length; i++)
        mrb_ary_push(mrb, list, mrb_int_value(mrb, p[i]));
    return list;
}

static mrb_value
prim_write_bytes(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    mrb_value list;
    (void)self;

    mrb_get_args(mrb, "iA", &address, &list);

    unsigned char *p = (unsigned char *)(uintptr_t)address;
    mrb_int len = RARRAY_LEN(list);
    for (mrb_int i = 0; i < len; i++)
        p[i] = (unsigned char)mrb_integer(mrb_ary_entry(list, i));
    return mrb_int_value(mrb, len);
}

/* The three facts about memory the Ruby side cannot find out itself: where
 * the image ends, where the bootloader's information is, and how much of the
 * address space the boot stub mapped. Each entry is [image_end, boot_info,
 * mapped_limit]; ruby/kernel/memory.rb reads the bootloader's structure from
 * there with peek32. */
static mrb_value
prim_memory_layout(mrb_state *mrb, mrb_value self)
{
    (void)self;

    mrb_value layout = mrb_ary_new_capa(mrb, 3);
    mrb_ary_push(mrb, layout, mrb_int_value(mrb, (mrb_int)memory_image_end()));
    mrb_ary_push(mrb, layout, mrb_int_value(mrb, (mrb_int)memory_boot_info()));
    mrb_ary_push(mrb, layout, mrb_int_value(mrb, (mrb_int)memory_mapped_limit()));
    return layout;
}

static mrb_value
prim_clock_millis(mrb_state *mrb, mrb_value self)
{
    (void)self;
    return mrb_int_value(mrb, (mrb_int)timer_millis());
}

static mrb_value
prim_peek64(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    (void)self;

    mrb_get_args(mrb, "i", &address);
    return mrb_int_value(mrb, (mrb_int)*(uint64_t *)(uintptr_t)address);
}

static mrb_value
prim_poke64(mrb_state *mrb, mrb_value self)
{
    mrb_int address, value;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &value);
    *(uint64_t *)(uintptr_t)address = (uint64_t)value;
    return mrb_nil_value();
}

static mrb_value
prim_halt(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    for (;;) __asm__ volatile ("cli; hlt");
}

void
bridge_init(mrb_state *mrb)
{
    struct RClass *kernel = mrb_module_get(mrb, "Kernel");
    syscall_module = mrb_module_get_under(mrb, kernel, "Syscall");

    /* Module functions, so the dispatcher calls them unqualified. */
    mrb_define_module_function(mrb, syscall_module, "serial_write",
                               prim_serial_write, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "clock_millis",
                               prim_clock_millis, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "serial_read",
                               prim_serial_read, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "copy_out",
                               prim_copy_out, MRB_ARGS_REQ(3));
    mrb_define_module_function(mrb, syscall_module, "memzero",
                               prim_memzero, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "cstring",
                               prim_cstring, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "embedded_files",
                               prim_embedded_files, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "memory_layout",
                               prim_memory_layout, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "peek32",
                               prim_peek32, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "poke16",
                               prim_poke16, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "serial_ready?",
                               prim_serial_ready, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "serial_read_ready",
                               prim_serial_read_ready, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "idle",
                               prim_idle, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "poke32",
                               prim_poke32, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "read_bytes",
                               prim_read_bytes, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "write_bytes",
                               prim_write_bytes, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "peek64",
                               prim_peek64, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "poke64",
                               prim_poke64, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "halt",
                               prim_halt, MRB_ARGS_NONE());
}

static long
dispatch_in_ruby(mrb_state *mrb, long n, long a1, long a2, long a3,
                 long a4, long a5, long a6)
{
    mrb_value argv[7];
    argv[0] = mrb_int_value(mrb, (mrb_int)n);
    argv[1] = mrb_int_value(mrb, (mrb_int)a1);
    argv[2] = mrb_int_value(mrb, (mrb_int)a2);
    argv[3] = mrb_int_value(mrb, (mrb_int)a3);
    argv[4] = mrb_int_value(mrb, (mrb_int)a4);
    argv[5] = mrb_int_value(mrb, (mrb_int)a5);
    argv[6] = mrb_int_value(mrb, (mrb_int)a6);

    int arena = mrb_gc_arena_save(mrb);
    mrb_value result = mrb_funcall_argv(mrb, mrb_obj_value(syscall_module),
                                        mrb_intern_lit(mrb, "dispatch"),
                                        7, argv);

    long ret;
    if (mrb->exc) {
#ifdef BRIDGE_TRACE
        mrb_print_error(mrb);
#endif
        /* Do not try to describe it: printing would need the console, which
         * may be the very thing that failed. */
        mrb->exc = 0;
        ret = -ENOSYS;
    }
    else if (mrb_integer_p(result)) {
        ret = (long)mrb_integer(result);
    }
    else {
        ret = -ENOSYS;
    }
    mrb_gc_arena_restore(mrb, arena);
    return ret;
}

long
kernel_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
    mrb_state *mrb = vm_state();

    if (mrb && !in_dispatch && is_routed(n)) {
#ifdef BRIDGE_TRACE
        { char b[8]; int i=0; long v=n; if(!v)b[i++]='0';
          while(v){b[i++]=(char)('0'+v%10);v/=10;}
          serial_puts("<sys "); while(i--) serial_putc(b[i]); serial_puts(">"); }
#endif
        in_dispatch = 1;
        long ret = dispatch_in_ruby(mrb, n, a1, a2, a3, a4, a5, a6);
        in_dispatch = 0;
#ifdef BRIDGE_TRACE
        { char b[16]; int i=0; long v=ret<0?-ret:ret; if(ret<0)serial_putc('-');
          if(!v)b[i++]='0'; while(v){b[i++]=(char)('0'+v%10);v/=10;}
          serial_puts("=> "); while(i--) serial_putc(b[i]); serial_puts("\n"); }
#endif
        return ret;
    }

    return kernel_syscall_c(n, a1, a2, a3, a4, a5, a6);
}

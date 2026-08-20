/* lwIP's port layer for this kernel.
 *
 * Everything lwIP calls a "compiler and platform abstraction" -- and arch.h is
 * explicit that these belong here and not in lwipopts.h. There is very little
 * of it, because musl supplies stdint.h, stddef.h, string.h and the rest, and
 * because x86_64 needs none of the packing or alignment help the small targets
 * lwIP usually runs on do.
 *
 * The unix port in lwIP's contrib/ would nearly do, but only nearly: it
 * declares a sys_arch with pthreads behind it, which NO_SYS does not want and
 * this machine does not have. Writing the four lines that are actually needed
 * is smaller than explaining which parts of somebody else's port to ignore. */

#ifndef PICORUBY_KERNEL_LWIP_ARCH_CC_H
#define PICORUBY_KERNEL_LWIP_ARCH_CC_H

#define BYTE_ORDER LITTLE_ENDIAN

/* lwIP decides whether the platform has ssize_t by looking for SSIZE_MAX, and
 * typedefs its own as int when it does not find one. musl has both, but hides
 * SSIZE_MAX behind a POSIX feature macro that this freestanding build does not
 * set -- so without this, lwIP declares ssize_t as int, musl declares it as
 * long, and the two collide. Saying it here is more contained than turning on
 * a feature macro for the whole kernel. */
#include <limits.h>
#include <sys/types.h>
#ifndef SSIZE_MAX
#define SSIZE_MAX LONG_MAX
#endif

/* Diagnostics and assertions go to the serial console, which is the only
 * output this machine has. Implemented in kernel/net.c rather than through
 * printf, which would reach musl's stdio and, through it, its allocator --
 * inside a syscall the kernel is in the middle of servicing. */
void net_printf(const char *format, ...);
void net_assert_failed(const char *message, const char *file, int line);

#define LWIP_PLATFORM_DIAG(x)   do { net_printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(m) do { net_assert_failed((m), __FILE__, __LINE__); } while (0)

/* getrandom is available and is what the kernel already uses to seed CRuby's
 * hashing. It is not a secure source here -- kernel/syscall.c says so -- and
 * lwIP wants this for initial sequence numbers and DHCP transaction ids, which
 * is a use that should be revisited alongside that one. */
/* Declared with a plain type because arch.h includes this file before it
 * defines u32_t; the cast in the macro is expanded where the type exists. */
unsigned int net_random(void);
#define LWIP_RAND() ((u32_t)net_random())

#endif /* PICORUBY_KERNEL_LWIP_ARCH_CC_H */

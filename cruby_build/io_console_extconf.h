/* Hand-written stand-in for the extconf.h that mkmf generates for
 * ext/io/console.
 *
 * The real one records the results of have_func and have_header probes, which
 * work by compiling and running programs. That is not possible for this
 * target, so the answers are stated here for the environment the kernel
 * provides: musl headers, and the CRuby the cross build produces.
 *
 * The termios path is the one that matters. io/console reaches raw mode
 * through TCGETS and TCSETS ioctls, which the kernel's own tty implementation
 * services, and Reline drives io/console for every keystroke it reads. */

#define HAVE_UNISTD_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_TERMIOS_H 1
#define HAVE_CFMAKERAW 1
#define HAVE_TTYNAME 1
#define HAVE_TTYNAME_R 1

/* CRuby 4.0 provides all of these. */
#define HAVE_RB_SYSERR_FAIL_STR 1
#define HAVE_RB_INTERNED_STR_CSTR 1
#define HAVE_RB_IO_PATH 1
#define HAVE_RB_IO_DESCRIPTOR 1
#define HAVE_RB_IO_GET_WRITE_IO 1
#define HAVE_RB_IO_CLOSED_P 1
#define HAVE_RB_IO_OPEN_DESCRIPTOR 1
#define HAVE_RB_IO_WAIT 1
#define HAVE_RB_RACTOR_LOCAL_STORAGE_VALUE_NEWKEY 1
#define HAVE_RUBY_FIBER_SCHEDULER_H 1

/* Deliberately absent:
 *
 * HAVE_TERMIO_H, HAVE_SGTTY_H, HAVE_STTY, HAVE_GTTY select the pre-POSIX
 * fallbacks, which musl does not provide.
 *
 * HAVE_RB_SCHEDULER_TIMEOUT names an entry point that is gone in 4.0.
 *
 * HAVE_RB_F_SEND would suppress the private copy of rb_f_send that console.c
 * carries, leaving the call at its only use site with nothing to resolve.
 * rb_f_send is declared in internal/enum.h and not exported, so a real
 * have_func probe would not find it either. */

/* Hand-written stand-in for the extconf.h that mkmf generates for ext/etc.
 *
 * WEBrick requires etc at the top of webrick/utils.rb and uses it only to
 * look up the user named by :User, so what matters is that require "etc"
 * succeeds and the rest is honest about this machine.
 *
 * getpwent and getgrent are left out on purpose: there is no /etc/passwd or
 * /etc/group, so Etc.getpwnam and friends become NotImplementedError instead
 * of searching a file that does not exist. uname is the kernel's own and
 * answers with nodename "kurenai". */
#define HAVE_SYS_UTSNAME_H 1
#define HAVE_UNAME 1
#define HAVE_SYSCONF 1
#define HAVE_RB_IO_DESCRIPTOR 1
#define HAVE_RB_DEPRECATE_CONSTANT 1

/* extconf.rb passes RbConfig's sysconfdir; the answer for a machine with no
 * prefix is the conventional one, even though nothing is there. */
#define SYSCONFDIR "/etc"

/* Hand-written stand-in for the extconf.h that mkmf generates for ext/socket.
 *
 * The real one records the results of have_func, have_type and have_header
 * probes, which work by compiling and running programs. That is not possible
 * for this target, so the answers are stated here for the environment the
 * kernel provides: musl's headers, and a machine whose only protocol family is
 * IPv4 over a polled NIC.
 *
 * This file decides more than which functions exist. ext/socket has fifteen
 * source files and all fifteen have to be linked, because
 * rsock_init_socket_init calls every rsock_init_* unconditionally -- so what
 * gets left out is decided here rather than in the source list. Omitting
 * HAVE_TYPE_STRUCT_SOCKADDR_UN empties unixsocket.c and unixserver.c;
 * omitting HAVE_STRUCT_MSGHDR_MSG_CONTROL empties ancdata.c; omitting
 * HAVE_GETIFADDRS empties ifaddr.c. Each init function survives as an empty
 * stub and the corresponding Ruby method becomes rb_f_notimplement, which is
 * the honest answer on a machine with no filesystem sockets, no fd passing and
 * no interface list.
 *
 * Unlike io/console's, this one cannot be supplied with -include: rubysocket.h
 * has an unconditional "#include RUBY_EXTCONF_H", so the name is passed as a
 * macro instead. See cruby_build/CMakeLists.txt. */

/* ---------------------------------------------------------------- headers
 *
 * All present in musl 1.2.5. sys/types.h, netdb.h, string.h, sys/socket.h and
 * netinet/in.h are the unconditional set extconf.rb assumes on any unix. */
#define HAVE_UNISTD_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_NETINET_IN_SYSTM_H 1
#define HAVE_NETINET_TCP_H 1
#define HAVE_NETINET_UDP_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NET_IF_H 1

/* Not optional, despite AF_PACKET being of no use here. musl declares
 * AF_PACKET in sys/socket.h, and socket.c's sockaddr_len switches on it under
 * a bare #ifdef AF_PACKET -- so struct sockaddr_ll has to be a complete type
 * or that arm does not compile. The header is what completes it. A real probe
 * on this target would find both of these, because musl ships both. */
#define HAVE_NETPACKET_PACKET_H 1
#define HAVE_NET_ETHERNET_H 1

/* ---------------------------------------------------------------- types */
#define HAVE_TYPE_SOCKLEN_T 1
#define HAVE_TYPE_STRUCT_ADDRINFO 1
#define HAVE_TYPE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_TYPE_STRUCT_IP_MREQ 1
#define HAVE_TYPE_STRUCT_IP_MREQN 1
#define HAVE_TYPE_STRUCT_IPV6_MREQ 1

/* ---------------------------------------------------------------- functions
 *
 * HAVE_SOCKET gates almost everything else in extconf.rb; without it the
 * extension builds as though the platform had no sockets at all.
 *
 * HAVE_ACCEPT4 is the one that decides which syscall the kernel has to
 * implement. With it, cloexec_accept passes SOCK_CLOEXEC|SOCK_NONBLOCK to
 * accept4 and accept(2) is never reached; without it, every accept is an
 * accept + two fcntls. One syscall, and the accepted socket is born
 * non-blocking, which is what the poll-driven design wants.
 *
 * musl declares gai_strerror as returning const char *. */
#define HAVE_SOCKET 1
#define HAVE_ACCEPT4 1
#define HAVE_GETADDRINFO 1
#define HAVE_GETNAMEINFO 1
#define HAVE_FREEADDRINFO 1
#define HAVE_GAI_STRERROR 1
#define GAI_STRERROR_CONST 1
#define HAVE_INET_NTOP 1
#define HAVE_INET_PTON 1
#define HAVE_GETHOSTNAME 1
#define HAVE_IF_NAMETOINDEX 1
#define HAVE_IF_INDEXTONAME 1

/* ---------------------------------------------------------------- IPv6
 *
 * Defined even though the kernel answers socket(AF_INET6, ...) with
 * EAFNOSUPPORT, because these do not claim that IPv6 works -- they claim that
 * the constants exist. mkconstants.rb guards Socket::AF_INET6 and every
 * Socket::IPV6_* on defined(INET6), and Addrinfo#ipv6only! in
 * ext/socket/lib/socket.rb looks up :V6ONLY unconditionally. Without these it
 * raises before a socket is ever created.
 *
 * With them, Socket.tcp_server_sockets asks for an AF_INET6 listener, gets
 * EAFNOSUPPORT, and its "rescue SystemCallError; next" moves on to the IPv4
 * one. Refusing a family is a normal thing for a kernel to do; not having the
 * constant is not. */
#define ENABLE_IPV6 1
#define INET6 1

/* ---------------------------------------------------------------- absent
 *
 * Each of these is left undefined for a reason, and the reason is what the
 * extension does with it rather than whether musl declares it.
 *
 * HAVE_PTHREAD_CREATE, HAVE_PTHREAD_DETACH, HAVE_PTHREAD_ATTR_SETDETACHSTATE
 *   kernel/musl_stubs.c makes __clone refuse, so any thread creation fails.
 *   Their absence is what selects FAST_FALLBACK_INIT_INETSOCK_IMPL 0 in
 *   rubysocket.h, keeping the Happy Eyeballs client path -- which creates a
 *   thread, a pipe and a select loop per connect -- out of the build.
 *   CMakeLists.txt also states GETADDRINFO_IMPL=0 explicitly, because their
 *   absence alone would select 1, which resolves names outside the GVL.
 *
 * HAVE_TYPE_STRUCT_SOCKADDR_UN, HAVE_SOCKETPAIR
 *   A unix socket needs a filesystem to name it and this one is read-only.
 *
 * HAVE_GETIFADDRS, HAVE_IFADDRS_H, HAVE_TYPE_STRUCT_SOCKADDR_DL
 *   musl implements getifaddrs over a netlink socket, which this kernel does
 *   not have. Socket.getifaddrs raises NotImplementedError instead of failing
 *   at runtime in a way that looks like a bug.
 *
 * HAVE_STRUCT_MSGHDR_MSG_CONTROL, HAVE_SENDMSG, HAVE_RECVMSG,
 * FD_PASSING_WORK_WITH_RECVMSG_MSG_PEEK
 *   No fd passing, and their absence keeps sendmsg(46) and recvmsg(47) off the
 *   syscall surface entirely.
 *
 * HAVE_TYPE_STRUCT_TCP_INFO and the forty HAVE_STRUCT_TCP_INFO_TCPI_*
 *   lwIP keeps no such statistics, so Socket::Option#tcp_info has nothing to
 *   report.
 *
 * HAVE_GETSERVBYPORT, HAVE_GETIPNODEBYNAME, HAVE_GETHOSTBYNAME2,
 * HAVE_FREEHOSTENT, HAVE_HSTERROR
 *   These want /etc/services or a resolver.
 *
 * HAVE_GETPEEREID, HAVE_GETPEERUCRED, HAVE_TYPE_STRUCT_SOCKCRED,
 * HAVE_TYPE_STRUCT_CMSGCRED
 *   There is one process and it has no credentials.
 *
 * HAVE_STRUCT_SOCKADDR_SA_LEN, HAVE_STRUCT_SOCKADDR_IN_SIN_LEN,
 * HAVE_STRUCT_SOCKADDR_IN6_SIN6_LEN
 *   4.4BSD fields. Claiming them on a Linux ABI would misread every sockaddr.
 *
 * RSTRING_SOCKLEN
 *   socklen_t is 4 bytes here and long is 8, so mkmf's own check would fail
 *   and fall back to RSTRING_LENINT -- which is what rubysocket.h defaults to.
 *
 * GETADDRINFO_EMU
 *   musl's getaddrinfo and getnameinfo are real.
 *
 * NEED_IF_NAMETOINDEX_DECL, NEED_IF_INDEXTONAME_DECL
 *   musl declares both in net/if.h.
 *
 * SOCKS, SOCKS5
 *   No proxy. sockssocket.c compiles to nothing and SOCKSSocket is absent. */

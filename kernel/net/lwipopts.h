/* lwIP's configuration for this kernel.
 *
 * Started from picoruby-socket's, which is what its lwIP glue was written
 * against, and changed in five places. Four of those are the difference
 * between a Cortex-M0 with a wifi chip on SPI and an x86_64 with a polled
 * PCI card; the fifth is this kernel's own hazard.
 *
 *   MEM_ALIGNMENT      4 -> 8.  lwIP stores pointers in its own heap, and
 *                      four-byte alignment on LP64 misaligns every one of
 *                      them.
 *
 *   MEM_LIBC_MALLOC    1 -> 0.  This is the kernel hazard. lwIP runs inside
 *                      Kernel::Syscall.dispatch, and musl's malloc is backed
 *                      by mmap, which is a syscall, which is dispatched by the
 *                      VM that is already running. The re-entrancy guard in
 *                      kernel/bridge.c would send it to the C path rather than
 *                      recursing, so it would not crash -- it would just mean
 *                      the network allocating out of a different arena than
 *                      the one the kernel is accounting for. Its own pool is
 *                      both safer and truthful.
 *
 *   MEM_SIZE           4000 -> 128KB.  Only meaningful once MEM_LIBC_MALLOC is
 *                      off, and 4KB does not go far next to a 16KB receive
 *                      window.
 *
 *   TCP_WND            16384 -> 4096.  Deliberately no larger than the
 *                      per-connection receive buffer in picoruby-socket's
 *                      port. Its receive callback drops data when that buffer
 *                      is full, and a window that permits more than the buffer
 *                      can hold is an invitation to lose some.
 *
 *   LWIP_ALTCP_TLS     1 -> 0.  No mbedTLS here. altcp itself stays, so the
 *                      port's altcp_* calls compile unchanged.
 *
 * And three pools are sized for a server with threads, which this is now.
 * picoruby-socket's are sized for a microcontroller holding one connection:
 *
 *   MEMP_NUM_TCP_PCB   5 -> 32.  Every connection takes one, and so does every
 *                      connection lately closed, for as long as it sits in
 *                      TIME_WAIT. With five, the sixth SYN of a burst found
 *                      nothing to allocate and was dropped, and the client
 *                      sent it again a second and then three seconds later: a
 *                      browser's handful of parallel requests came back in six
 *                      seconds instead of six milliseconds.
 *
 *   MEMP_NUM_TCP_SEG   32 -> 128.  Unacknowledged segments, across every
 *                      connection; TCP_SND_QUEUELEN alone allows one
 *                      connection 32.
 *
 *   PBUF_POOL_SIZE     24 -> 64.  Received frames waiting for lwIP. A burst
 *                      of connections arrives as a burst of frames.
 *
 * LWIP_NETIF_TX_SINGLE_PBUF is inherited and worth keeping: every transmit
 * arrives as one contiguous pbuf, so the driver's link output copies once and
 * never walks a chain. */

#ifndef KURENAI_LWIPOPTS_H
#define KURENAI_LWIPOPTS_H

/* No threads and no sockets: lwIP is driven by being polled, from the wait
 * loops in the Ruby kernel. NO_SYS 1 is also what makes the whole of
 * contrib/ports unnecessary -- the port is sys_now() and a netif. */
#define NO_SYS                      1
#define LWIP_SOCKET                 0
#define LWIP_NETCONN                0

/* lwIP's critical sections, which default to on. There is nothing to be
 * protected from: nothing runs concurrently with the stack. The card raises no
 * interrupt, the timer's interrupt never touches the network and never
 * switches threads inside the kernel, and the whole of lwIP executes inside
 * one call to Kernel::Syscall.dispatch. Leaving this at 1 would want a
 * sys_arch_protect this port has no honest implementation for. */
#define SYS_LIGHTWEIGHT_PROT        0

#define MEM_LIBC_MALLOC             0
#define MEM_ALIGNMENT               8
#define MEM_SIZE                    (128 * 1024)

#define MEMP_NUM_TCP_PCB            32
#define MEMP_NUM_TCP_SEG            128
#define MEMP_NUM_ARP_QUEUE          10
#define PBUF_POOL_SIZE              64

#define LWIP_ARP                    1
#define LWIP_ETHERNET               1
#define LWIP_ICMP                   1
#define LWIP_RAW                    0
#define LWIP_IPV4                   1
#define LWIP_TCP                    1
#define LWIP_UDP                    1
#define LWIP_DNS                    1
#define LWIP_DHCP                   1

#define TCP_MSS                     1460
#define TCP_WND                     4096
#define TCP_SND_BUF                 (8 * TCP_MSS)
#define TCP_SND_QUEUELEN            ((4 * (TCP_SND_BUF) + (TCP_MSS - 1)) / (TCP_MSS))
#define LWIP_TCP_KEEPALIVE          1

#define LWIP_NETIF_TX_SINGLE_PBUF   1
#define LWIP_NETIF_STATUS_CALLBACK  1
#define LWIP_NETIF_LINK_CALLBACK    1
#define LWIP_NETIF_HOSTNAME         1

/* QEMU's user-mode network answers DHCP, so the address is asked for rather
 * than assumed. DHCP's own ARP probe is off because nothing else is on this
 * segment to conflict with, and it costs a second of boot to prove it. */
#define DHCP_DOES_ARP_CHECK         0
#define LWIP_DHCP_DOES_ACD_CHECK    0

/* altcp is kept because picoruby-socket's port is written against it; the TLS
 * layers behind it are not. */
#define LWIP_ALTCP                  1
#define LWIP_ALTCP_TLS              0
#define LWIP_ALTCP_TLS_MBEDTLS      0

/* Checksums in C, since there is no hardware to hand them to and no assembly
 * worth writing before something is measured. */
#define LWIP_CHKSUM_ALGORITHM       3

/* Statistics cost memory and are only readable from a debugger this kernel
 * does not have. */
#define LWIP_STATS                  0

/* Diagnostics, the random source and the byte order are in
 * kernel/net/arch/cc.h. lwIP's arch.h is explicit that they belong to the port
 * rather than to the options. */

#endif /* KURENAI_LWIPOPTS_H */

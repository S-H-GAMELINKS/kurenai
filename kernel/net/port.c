/* picoruby-socket's port layer, for this kernel.
 *
 * The gem's C API is written against four helpers that a port supplies. On the
 * Raspberry Pi Pico W they wrap the cyw43 wifi chip's driver; here the driver
 * is Ruby, and that changes what these can honestly do.
 *
 * lwip_begin and lwip_end are the gem's critical section. There is nothing to
 * exclude: the card raises no interrupt, and the whole of lwIP runs inside one
 * call to Kernel::Syscall.dispatch. Empty is the correct implementation, not a
 * stub standing in for one.
 *
 * Net_poll is where the design shows. The gem calls it -- as cyw43_arch_poll --
 * after queueing a transmit and before checking for an accepted connection, so
 * that the link gets a turn. Here the link is a Ruby object, and C does not
 * call into the VM: an exception raised in an lwIP callback would unwind
 * through frames that know nothing about mruby. So the Ruby side pumps around
 * every one of these calls instead, and by the time the port asks, the turn has
 * already been taken. It is empty for the same reason lwip_begin is: the work
 * is genuinely already done, at a place better suited to doing it.
 *
 * Net_busy_wait_ms is the one that cannot be empty and cannot be complete. The
 * gem's blocking paths use it -- a blocking read, a blocking connect, DNS --
 * and none of those is on this kernel's road, because waiting belongs where the
 * pump is. But TCPServer_close reaches it too, to give lwIP time to finish
 * closing a listening pcb, and that is a legitimate use.
 *
 * So it does what it can from C: it runs lwIP's timers. What it cannot do is
 * move frames, because that needs the driver, and the driver is Ruby. A path
 * that waits here for something arriving from the network will therefore time
 * out rather than quietly working at a hundredth of the intended rate -- which
 * is the better of the two failures, because it is visible. */

#include <stdint.h>

#include "lwip/dns.h"
#include "lwip/ip_addr.h"
#include "lwip/timeouts.h"

#include "../kernel.h"
#include "socket.h"

void
lwip_begin(void)
{
}

void
lwip_end(void)
{
}

void
Net_poll(void)
{
}

void
Net_busy_wait_ms(int ms)
{
    uint64_t deadline = timer_millis() + (uint64_t)(ms < 0 ? 0 : ms);

    while (timer_millis() < deadline) {
        /* Timers, which is everything lwIP can advance without the link:
         * retransmission, ARP expiry, and the close it is usually waiting on.
         * Frames stay in the queue until the Ruby pump next runs. */
        sys_check_timeouts();
        __asm__ volatile ("pause");
    }
}

/* Name resolution, which nothing needs yet: a server is given the addresses it
 * binds to, and musl resolves numeric addresses without a resolver. Returning
 * failure is the truthful answer until the wait for a DNS reply has somewhere
 * to happen -- which is the Ruby side, not here. */
int
Net_get_ip(const char *name, void *ip)
{
    (void)name;
    (void)ip;
    return -1;
}

/* lwIP, and the seam between it and the driver written in Ruby.
 *
 * The protocol stack is C and the device is Ruby, which is the opposite of the
 * usual arrangement and is deliberate: a driver is a conversation with
 * registers and a TCP implementation is not, so the line is drawn where the
 * difficulty actually changes. lwIP is also the stack PicoRuby's own socket
 * layer is written against, which is what makes the next step possible at all.
 *
 * Nothing here calls into Ruby. It would work -- the VM is running, and a
 * nested funcall is legal -- but an exception raised in a callback would unwind
 * through lwIP's C frames, which know nothing about mruby. So frames cross in
 * one direction at a time, through a queue and a copy, and the Ruby side asks.
 *
 * Everything is polled. kernel/idt.c installs the CPU's exception vectors and
 * nothing else, so there is no interrupt to drive this from; Kernel::Net.pump
 * is called from the wait loops in the syscall dispatcher. That means the
 * network only advances while the kernel is servicing a syscall, which for a
 * server is exactly when it needs to. */

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

#include <mruby.h>
#include <mruby/class.h>

#include "lwip/dhcp.h"
#include "lwip/etharp.h"
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/timeouts.h"
#include "netif/ethernet.h"

#include "kernel.h"

/* ---------------------------------------------------------------- diagnostics
 *
 * lwIP wants a printf for its assertions. Formatting on the stack keeps this
 * out of musl's allocator, which matters because an assertion is most likely to
 * fire when something is already wrong with memory. */

void
net_printf(const char *format, ...)
{
    char line[256];
    va_list args;

    va_start(args, format);
    int n = vsnprintf(line, sizeof(line), format, args);
    va_end(args);

    if (n > 0) serial_write(line, (size_t)n > sizeof(line) ? sizeof(line) : (size_t)n);
}

void
net_assert_failed(const char *message, const char *file, int line)
{
    serial_puts("lwip: assertion failed: ");
    serial_puts(message);
    serial_puts(" at ");
    serial_puts(file);
    serial_putc(':');
    serial_put_uint((uint64_t)line);
    serial_putc('\n');
    for (;;) __asm__ volatile ("cli; hlt");
}

/* lwIP wants randomness for initial sequence numbers and DHCP transaction ids.
 * This is the same xorshift over the timestamp counter that seeds CRuby's
 * hashing, and it is no more random here than it is there; kernel/syscall.c
 * says so at the other use site. Both want revisiting together. */
unsigned int
net_random(void)
{
    static uint64_t state;

    if (state == 0) state = timer_nanos() | 1u;
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return (unsigned int)state;
}

/* lwIP's clock. Milliseconds since boot is exactly what the TSC gives. */
uint32_t
sys_now(void)
{
    return (uint32_t)timer_millis();
}

/* ---------------------------------------------------------------- transmit
 *
 * lwIP hands a frame down; the Ruby driver takes it away. A queue rather than a
 * direct call because the two run at different times: link output happens
 * wherever lwIP decided to send something, and the driver runs when the pump
 * next asks.
 *
 * LWIP_NETIF_TX_SINGLE_PBUF means each frame arrives as one contiguous pbuf, so
 * this is one memcpy and never a walk down a chain. */

#define TX_SLOTS  8
#define TX_SLOT_BYTES 1536

static uint8_t  tx_queue[TX_SLOTS][TX_SLOT_BYTES];
static uint16_t tx_length[TX_SLOTS];
static unsigned tx_head;    /* the driver takes from here */
static unsigned tx_tail;    /* lwIP puts here */
static unsigned tx_count;
static unsigned tx_dropped;

static struct netif interface;
static int interface_started;

static err_t
low_level_output(struct netif *netif, struct pbuf *p)
{
    (void)netif;

    if (p->tot_len > TX_SLOT_BYTES) return ERR_MEM;
    if (tx_count == TX_SLOTS) {
        /* Nothing has drained the queue. Dropping is honest: the alternative
         * is blocking here, and there is nobody else to run. TCP retransmits;
         * ARP asks again. */
        tx_dropped++;
        return ERR_MEM;
    }

    pbuf_copy_partial(p, tx_queue[tx_tail], p->tot_len, 0);
    tx_length[tx_tail] = p->tot_len;
    tx_tail = (tx_tail + 1) % TX_SLOTS;
    tx_count++;
    return ERR_OK;
}

/* Copies the frame at the head of the queue to an address the caller owns --
 * the driver's own transmit buffer, so the bytes land where the card will read
 * them. Returns the length, or 0 when there is nothing queued. */
static mrb_value
prim_net_tx_take(mrb_state *mrb, mrb_value self)
{
    mrb_int destination;
    (void)self;

    mrb_get_args(mrb, "i", &destination);
    if (tx_count == 0) return mrb_int_value(mrb, 0);

    uint16_t length = tx_length[tx_head];
    __builtin_memcpy((void *)(uintptr_t)destination, tx_queue[tx_head], length);
    tx_head = (tx_head + 1) % TX_SLOTS;
    tx_count--;
    return mrb_int_value(mrb, (mrb_int)length);
}

/* ---------------------------------------------------------------- receive
 *
 * The driver found a frame in the card's ring and says where it is. The bytes
 * are copied into a pbuf because the descriptor is handed back to the card as
 * soon as the driver is done, and lwIP keeps what it is given for longer than
 * that. */
static mrb_value
prim_net_input(mrb_state *mrb, mrb_value self)
{
    mrb_int address, length;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &length);
    if (!interface_started || length <= 0) return mrb_false_value();

    struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)length, PBUF_POOL);
    if (!p) return mrb_false_value();

    if (pbuf_take(p, (const void *)(uintptr_t)address, (u16_t)length) != ERR_OK) {
        pbuf_free(p);
        return mrb_false_value();
    }

    if (interface.input(p, &interface) != ERR_OK) {
        pbuf_free(p);
        return mrb_false_value();
    }
    return mrb_true_value();
}

/* lwIP's timers: retransmission, ARP expiry, the DHCP state machine. Nothing
 * happens without this being called. */
static mrb_value
prim_net_timeouts(mrb_state *mrb, mrb_value self)
{
    (void)self;
    if (interface_started) sys_check_timeouts();
    return mrb_nil_value();
}

/* ---------------------------------------------------------------- bring-up */

static err_t
interface_init(struct netif *netif)
{
    netif->name[0] = 'e';
    netif->name[1] = 'n';
    netif->output = etharp_output;
    netif->linkoutput = low_level_output;
    netif->mtu = 1500;
    netif->hwaddr_len = ETH_HWADDR_LEN;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP |
                   NETIF_FLAG_ETHERNET | NETIF_FLAG_LINK_UP;
    return ERR_OK;
}

/* The MAC arrives packed into one integer, most significant byte first, which
 * is the order it is written and read in. Six arguments would say the same
 * thing less clearly. */
static mrb_value
prim_net_up(mrb_state *mrb, mrb_value self)
{
    mrb_int mac;
    (void)self;

    mrb_get_args(mrb, "i", &mac);
    if (interface_started) return mrb_true_value();

    lwip_init();

    for (int i = 0; i < ETH_HWADDR_LEN; i++)
        interface.hwaddr[i] = (uint8_t)((uint64_t)mac >> (8 * (5 - i)));

    /* No address of its own yet: DHCP supplies it. ethernet_input rather than
     * tcpip_input, because with NO_SYS there is no thread to hand it to. */
    if (netif_add(&interface, IP4_ADDR_ANY4, IP4_ADDR_ANY4, IP4_ADDR_ANY4,
                  NULL, interface_init, ethernet_input) == NULL)
        return mrb_false_value();

    netif_set_default(&interface);
    netif_set_up(&interface);
    netif_set_link_up(&interface);
    interface_started = 1;

    if (dhcp_start(&interface) != ERR_OK) return mrb_false_value();
    return mrb_true_value();
}

/* Has DHCP finished? An interface with no address is up in the sense that it
 * can send, and not in the sense anything cares about. */
static mrb_value
prim_net_bound(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    if (!interface_started) return mrb_false_value();
    return ip4_addr_isany_val(*netif_ip4_addr(&interface))
        ? mrb_false_value() : mrb_true_value();
}

/* The three addresses, as integers in host order. Formatting them is the Ruby
 * side's business; producing them here as Fixnums keeps the pump allocation
 * free. */
static mrb_value
prim_net_address(mrb_state *mrb, mrb_value self)
{
    (void)self;
    return mrb_int_value(mrb, (mrb_int)lwip_ntohl(netif_ip4_addr(&interface)->addr));
}

static mrb_value
prim_net_netmask(mrb_state *mrb, mrb_value self)
{
    (void)self;
    return mrb_int_value(mrb, (mrb_int)lwip_ntohl(netif_ip4_netmask(&interface)->addr));
}

static mrb_value
prim_net_gateway(mrb_state *mrb, mrb_value self)
{
    (void)self;
    return mrb_int_value(mrb, (mrb_int)lwip_ntohl(netif_ip4_gw(&interface)->addr));
}

/* Frames lwIP wanted to send and nothing collected. Reported because a queue
 * that silently overflows looks exactly like a network that is merely slow. */
static mrb_value
prim_net_dropped(mrb_state *mrb, mrb_value self)
{
    (void)self;
    return mrb_int_value(mrb, (mrb_int)tx_dropped);
}

void
net_init(mrb_state *mrb, struct RClass *module)
{
    mrb_define_module_function(mrb, module, "net_up",
                               prim_net_up, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, module, "net_input",
                               prim_net_input, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, module, "net_tx_take",
                               prim_net_tx_take, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, module, "net_timeouts",
                               prim_net_timeouts, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, module, "net_bound?",
                               prim_net_bound, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, module, "net_address",
                               prim_net_address, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, module, "net_netmask",
                               prim_net_netmask, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, module, "net_gateway",
                               prim_net_gateway, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, module, "net_tx_dropped",
                               prim_net_dropped, MRB_ARGS_NONE());
}

/* Monotonic time from the timestamp counter.
 *
 * CRuby wants a clock before it will finish starting, and a clock that never
 * advances is worse than none: code that waits for time to pass would spin
 * forever. The TSC counts cycles, so it needs calibrating against something
 * with a known frequency; the PIT is the one piece of hardware whose rate can
 * be assumed on any PC. */

#include <stdint.h>

#include "kernel.h"

#define PIT_FREQUENCY_HZ 1193182u
#define PIT_CHANNEL2     0x42
#define PIT_COMMAND      0x43
#define PORT_61          0x61   /* channel 2 gate and output status */

static uint64_t tsc_per_ms;
static uint64_t tsc_at_boot;

static inline uint64_t rdtsc(void)
{
    uint32_t lo, hi;
    __asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

void
timer_init(void)
{
    /* Count down 10ms worth of PIT ticks and see how far the TSC moves. */
    const uint16_t ticks = (uint16_t)(PIT_FREQUENCY_HZ / 100u);

    /* Gate channel 2 on, speaker off: the timer runs but makes no sound. */
    outb(PORT_61, (uint8_t)((inb(PORT_61) & ~0x02u) | 0x01u));

    outb(PIT_COMMAND, 0xB2);            /* channel 2, lo/hi byte, mode 0 */
    outb(PIT_CHANNEL2, (uint8_t)(ticks & 0xFF));
    outb(PIT_CHANNEL2, (uint8_t)(ticks >> 8));

    /* Restarting the gate reloads the counter. */
    uint8_t gate = (uint8_t)(inb(PORT_61) & ~0x01u);
    outb(PORT_61, gate);
    outb(PORT_61, (uint8_t)(gate | 0x01u));

    uint64_t start = rdtsc();
    while (!(inb(PORT_61) & 0x20u))     /* wait for the countdown to finish */
        __asm__ volatile ("pause");
    uint64_t end = rdtsc();

    tsc_per_ms = (end - start) / 10u;
    if (tsc_per_ms == 0) tsc_per_ms = 1;  /* never divide by zero later */
    tsc_at_boot = end;
}

uint64_t
timer_millis(void)
{
    return (rdtsc() - tsc_at_boot) / tsc_per_ms;
}

uint64_t
timer_nanos(void)
{
    uint64_t elapsed = rdtsc() - tsc_at_boot;

    /* Scale in two steps: elapsed * 1000000 would overflow within an hour. */
    uint64_t ms = elapsed / tsc_per_ms;
    uint64_t rem = elapsed % tsc_per_ms;
    return ms * 1000000u + (rem * 1000000u) / tsc_per_ms;
}

/* ---------------------------------------------------------------- wall clock
 *
 * The TSC says how long the machine has been up, not what time it is. The
 * date comes from the CMOS clock, read once at boot by ruby/kernel/clock.rb,
 * which hands over the Unix time it worked out. What is kept is the
 * difference between the two clocks, so the wall clock advances with the TSC
 * and never steps backwards under a monotonic reader.
 *
 * Until it is set the offset is zero and the wall clock reads as time since
 * boot, which is what every clock read before there was a date to give. */

static uint64_t realtime_offset;

void
timer_set_realtime(uint64_t unix_seconds)
{
    uint64_t now = unix_seconds * 1000000000u;
    uint64_t up = timer_nanos();
    realtime_offset = now > up ? now - up : 0;
}

uint64_t
timer_realtime_nanos(void)
{
    return timer_nanos() + realtime_offset;
}

/* An absolute time on the wall clock, as a time on the monotonic one -- for a
 * wait whose deadline was given in CLOCK_REALTIME. A deadline from before the
 * machine started is already past; 1 rather than 0, because 0 means "no
 * deadline" to the waits that take one. */
uint64_t
timer_from_realtime(uint64_t realtime_nanos)
{
    if (realtime_nanos <= realtime_offset) return 1;
    return realtime_nanos - realtime_offset;
}

/* COM1 driver.
 *
 * Polled, no interrupts. That is enough for a console and keeps the boot path
 * free of an interrupt controller, which nothing else needs yet. */

#include "kernel.h"

#define COM1 0x3F8

/* Register offsets from the base port. */
#define COM_DATA          0
#define COM_INT_ENABLE    1
#define COM_FIFO_CTRL     2
#define COM_LINE_CTRL     3
#define COM_MODEM_CTRL    4
#define COM_LINE_STATUS   5

#define LINE_STATUS_DATA_READY  0x01
#define LINE_CTRL_DLAB          0x80
#define LINE_CTRL_8N1           0x03

static inline void outb(uint16_t port, uint8_t value)
{
    __asm__ volatile ("outb %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint8_t inb(uint16_t port)
{
    uint8_t value;
    __asm__ volatile ("inb %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

void
serial_init(void)
{
    outb(COM1 + COM_INT_ENABLE, 0x00);              /* polled, no interrupts */
    outb(COM1 + COM_LINE_CTRL,  LINE_CTRL_DLAB);    /* divisor latch */
    outb(COM1 + COM_DATA,       0x03);              /* 38400 baud */
    outb(COM1 + COM_INT_ENABLE, 0x00);
    outb(COM1 + COM_LINE_CTRL,  LINE_CTRL_8N1);
    outb(COM1 + COM_FIFO_CTRL,  0xC7);              /* enable and clear FIFOs */
    outb(COM1 + COM_MODEM_CTRL, 0x0B);              /* DTR, RTS, OUT2 */
}

void
serial_putc(char c)
{
    /* Terminals on the other end expect CRLF. */
    if (c == '\n') outb(COM1 + COM_DATA, '\r');
    outb(COM1 + COM_DATA, (uint8_t)c);
}

void
serial_puts(const char *s)
{
    while (*s) serial_putc(*s++);
}

void
serial_write(const char *buf, size_t len)
{
    for (size_t i = 0; i < len; i++) serial_putc(buf[i]);
}

int
serial_data_ready(void)
{
    return inb(COM1 + COM_LINE_STATUS) & LINE_STATUS_DATA_READY;
}

int
serial_getc(void)
{
    while (!serial_data_ready())
        __asm__ volatile ("pause");
    return inb(COM1 + COM_DATA);
}

size_t
serial_read(char *buf, size_t len)
{
    if (len == 0) return 0;

    /* Block for the first byte, then take whatever else has arrived. A caller
     * asking to read gets at least one byte or waits; it never spins. */
    buf[0] = (char)serial_getc();
    size_t i = 1;
    while (i < len && serial_data_ready())
        buf[i++] = (char)inb(COM1 + COM_DATA);
    return i;
}

/* Kernel entry.
 *
 * The order here is the dependency order, and each line prints so that a
 * failure names the stage it happened in rather than showing up as silence.
 * TLS comes before anything that might touch errno, which is nearly the first
 * thing libc does. */

#include "kernel.h"

void
kernel_main(void)
{
    serial_init();
    serial_puts("boot ok\n");

    /* First, so that everything after it can fail legibly. */
    idt_init();
    serial_puts("traps ok\n");

    timer_init();
    serial_puts("timer ok\n");

    /* After the TSC is calibrated, because it is how the tick is checked. */
    irq_init();

    libc_init();
    serial_puts("libc ok\n");

    /* The code running now becomes thread 1. */
    task_init();

    /* Memory is set up by the Ruby side as it boots: the VM runs from its own
     * pool, and nothing asks for pages before CRuby starts. */
    vm_start();
    if (!vm_state()) {
        serial_puts("kernel: the Ruby side did not come up\n");
        return;
    }

    /* From here on, writing to the console is Ruby's job. Routing is switched
     * on only once the VM is known good: if the dispatcher were unavailable,
     * every write would fail, including the ones reporting why. */
    /* The console and the filesystem are Ruby's from here on. What stays in C
     * is the machine: memory, time, the CPU. */
    bridge_route(1   /* SYS_write  */);
    bridge_route(20  /* SYS_writev */);  /* what musl's stdio actually uses */
    bridge_route(0   /* SYS_read   */);
    bridge_route(2   /* SYS_open   */);
    bridge_route(257 /* SYS_openat */);
    bridge_route(3   /* SYS_close  */);
    bridge_route(5   /* SYS_fstat  */);
    bridge_route(4   /* SYS_stat   */);
    bridge_route(6   /* SYS_lstat  */);
    bridge_route(262 /* SYS_newfstatat */);
    bridge_route(79  /* SYS_getcwd     */);
    bridge_route(21  /* SYS_access     */);
    bridge_route(269 /* SYS_faccessat  */);
    bridge_route(439 /* SYS_faccessat2 */);
    bridge_route(16  /* SYS_ioctl      */);   /* the terminal is Ruby's now */
    bridge_route(7   /* SYS_poll       */);
    bridge_route(271 /* SYS_ppoll      */);
    bridge_route(8   /* SYS_lseek  */);
    bridge_route(22  /* SYS_pipe   */);
    bridge_route(293 /* SYS_pipe2  */);
    bridge_route(9   /* SYS_mmap   */);
    bridge_route(11  /* SYS_munmap */);

    /* Sockets. accept is not routed and does not need to be: ext/socket's
     * cloexec_accept always passes SOCK_CLOEXEC|SOCK_NONBLOCK, and musl only
     * falls back to accept(2) when the flags are zero -- so accept4 is the
     * whole of the accept path. If that ever stops being true, the console
     * says "unhandled syscall 43" rather than misbehaving quietly.
     *
     * connect, sendto and recvfrom are likewise absent. They are the client
     * and datagram paths, and a server needs neither; reads and writes on a
     * connection arrive as read, write and writev. */
    bridge_route(41  /* SYS_socket      */);
    bridge_route(49  /* SYS_bind        */);
    bridge_route(50  /* SYS_listen      */);
    bridge_route(288 /* SYS_accept4     */);
    bridge_route(51  /* SYS_getsockname */);
    bridge_route(52  /* SYS_getpeername */);
    bridge_route(54  /* SYS_setsockopt  */);
    bridge_route(55  /* SYS_getsockopt  */);
    bridge_route(48  /* SYS_shutdown    */);

    /* Waiting. poll is what CRuby retries a would-block read with; select is
     * what IO.select lowers to, which is how a server watches several
     * listeners at once. Both had to exist before either was useful. */
    bridge_route(23  /* SYS_select   */);
    bridge_route(270 /* SYS_pselect6 */);

    /* Writing, and the rest of what a writable filesystem is asked: files are
     * written into pages from ruby/kernel/memory.rb, directories are listed
     * with getdents64, and names are made and removed. Policy, all of it, so
     * Ruby's. */
    bridge_route(17  /* SYS_pread64    */);
    bridge_route(18  /* SYS_pwrite64   */);
    bridge_route(77  /* SYS_ftruncate  */);
    bridge_route(217 /* SYS_getdents64 */);
    bridge_route(82  /* SYS_rename     */);
    bridge_route(264 /* SYS_renameat   */);
    bridge_route(316 /* SYS_renameat2  */);
    bridge_route(83  /* SYS_mkdir      */);
    bridge_route(258 /* SYS_mkdirat    */);
    bridge_route(84  /* SYS_rmdir      */);
    bridge_route(87  /* SYS_unlink     */);
    bridge_route(263 /* SYS_unlinkat   */);
    serial_puts("syscall routing ok\n");

    /* Boot has been kernel code throughout. CRuby is not, and from here a
     * tick may switch away from it to another thread. */
    preempt_enable();
    cruby_start();

    vm_report_syscalls();
    serial_puts("kernel: done\n");
}

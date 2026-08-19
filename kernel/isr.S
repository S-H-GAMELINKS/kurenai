/* Exception entry stubs.
 *
 * The CPU pushes an error code for some vectors and not others, so the stubs
 * push a zero where it is missing. After that every vector reaches the common
 * path with the same frame, and the handler can be written once in C.
 *
 * Nothing here returns. A fault at this stage of the system means something is
 * wrong that continuing would only obscure. */

.section .text
.code64

.macro ISR_NOERR vector
.global isr_\vector
isr_\vector:
    pushq $0
    pushq $\vector
    jmp isr_common
.endm

.macro ISR_ERR vector
.global isr_\vector
isr_\vector:
    pushq $\vector
    jmp isr_common
.endm

ISR_NOERR 0     /* divide error */
ISR_NOERR 1     /* debug */
ISR_NOERR 2     /* NMI */
ISR_NOERR 3     /* breakpoint */
ISR_NOERR 4     /* overflow */
ISR_NOERR 5     /* bound range */
ISR_NOERR 6     /* invalid opcode */
ISR_NOERR 7     /* device not available */
ISR_ERR   8     /* double fault */
ISR_NOERR 9
ISR_ERR   10    /* invalid TSS */
ISR_ERR   11    /* segment not present */
ISR_ERR   12    /* stack fault */
ISR_ERR   13    /* general protection */
ISR_ERR   14    /* page fault */
ISR_NOERR 15
ISR_NOERR 16    /* x87 floating point */
ISR_ERR   17    /* alignment check */
ISR_NOERR 18    /* machine check */
ISR_NOERR 19    /* SIMD floating point */
ISR_NOERR 20    /* virtualization */
ISR_ERR   21    /* control protection */
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_ERR   30    /* security */
ISR_NOERR 31

isr_common:
    /* Everything the report needs, in the order struct fault_frame declares
     * it. The stack already holds vector, error code, and the frame the CPU
     * pushed. */
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %rdi
    call fault_report

1:  cli
    hlt
    jmp 1b

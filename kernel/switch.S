/* Running C on a stack other than the caller's. */

.section .text
.code64

/* long call_on_stack(long (*fn)(void *), void *arg, void *stack_top)
 *
 * Calls fn(arg) with rsp at stack_top, which must be 16-byte aligned, and
 * comes back to the caller's stack. rbp holds the way back: it is
 * callee-saved, so fn leaves it alone. */
.global call_on_stack
call_on_stack:
    pushq %rbp
    movq %rsp, %rbp
    movq %rdx, %rsp
    movq %rdi, %rax
    movq %rsi, %rdi
    call *%rax
    movq %rbp, %rsp
    popq %rbp
    ret

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

/* void switch_to(uint64_t *save_rsp, uint64_t next_rsp)
 *
 * Saves the callee-saved registers on the current stack, records where that
 * stack ended up, and resumes the task whose stack is next_rsp -- either
 * inside its own switch_to, which returns into schedule(), or at
 * task_trampoline for a task that has never run. Caller-saved registers need
 * no saving: the caller already assumed they were lost. CRuby's Fiber
 * switcher, coroutine/amd64/Context.S, is the same shape. */
.global switch_to
switch_to:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, (%rdi)
    movq %rsi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

/* Where a new task starts, with the function musl gave __clone in r12 and its
 * argument in r13 (see task_clone). What musl's own clone.s does in the child:
 * call func(arg), and exit the thread with what it returns. */
.global task_trampoline
task_trampoline:
    call task_started
    movq %r13, %rdi
    call *%r12
    movl %eax, %edi
    call task_exit
    ud2

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

/* void switch_from_irq(uint64_t next_rsp)
 *
 * The second half of switch_to, for irq_tick: the interrupted task has
 * already been saved -- onto its own stack, by irq_tick -- and there is
 * nothing on the IST stack worth keeping, so this only loads. Interrupts are
 * still off from the gate; sti comes last, once rsp is the next task's, so the
 * next tick cannot arrive while anything is half done. sti takes effect after
 * the following instruction, which is the ret. */
.global switch_from_irq
switch_from_irq:
    movq %rdi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    sti
    ret

/* Where a preempted task resumes: switch_to (or switch_from_irq) returns here
 * with rsp at the irq_frame irq_tick copied onto the task's stack. task_resumed
 * finishes the switch, and irq_resume puts back every register the tick saved,
 * so the code that was interrupted never sees a difference. rsp is 16-byte
 * aligned here, as a call wants. */
.global irq_resume_task
irq_resume_task:
    call task_resumed
    jmp irq_resume

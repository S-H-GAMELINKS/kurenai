/* Static extension registration for picoruby-kernel.
 *
 * A dynamically linked ruby gets an empty Init_ext from dmydln.c and loads
 * extensions with dlopen. A statically linked one gets a generated
 * ext/extinit.c instead. There is no dynamic loading here and no generated
 * file either, so this is that file, written by hand.
 *
 * ruby_init_ext registers the entry point and records the feature as loaded,
 * which is what makes require "io/console" and require "ripper" succeed
 * without touching a filesystem. prism_init.c in the CRuby tree is the same
 * pattern.
 *
 * All three exist for irb. Reline drives io/console for raw-mode input and
 * io/wait to poll it, and IRB::RubyLex uses Ripper::Lexer to decide whether an
 * input line is complete. */

void ruby_init_ext(const char *name, void (*init)(void));

void Init_console(void);
void Init_wait(void);
void Init_stringio(void);
void Init_ripper(void);

void
Init_ext(void)
{
    ruby_init_ext("io/console.so", Init_console);
    ruby_init_ext("io/wait.so", Init_wait);
    ruby_init_ext("stringio.so", Init_stringio);
    ruby_init_ext("ripper.so", Init_ripper);
}

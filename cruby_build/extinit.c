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
 * Four exist for irb. Reline drives io/console for raw-mode input and io/wait
 * to poll it, and IRB::RubyLex uses Ripper::Lexer to decide whether an input
 * line is complete.
 *
 * socket and io/nonblock exist for the HTTP server. socket is the one place
 * where registering the feature is not the whole story: require "socket" finds
 * socket.so already provided and goes on to load /socket.rb from the Ruby
 * filesystem, which is where Addrinfo#listen and Socket.tcp_server_sockets
 * live. Registering without embedding that file gives a require that succeeds
 * and an API with holes in it.
 *
 * date_core is there for require "time": lib/time.rb requires "date" first,
 * and /date.rb is what requires date_core.so, not the other way round.
 *
 * json is two extensions, json/ext/parser and json/ext/generator, required by
 * those names from json/ext.rb.
 *
 * openssl is the same shape as socket and date: require "openssl" loads
 * /openssl.rb, which requires openssl.so and then defines the half of the API
 * written in Ruby -- OpenSSL::SSL::SSLSocket#connect among it. It requires
 * "digest" while it initialises, which is /digest.rb requiring digest.so. */

void ruby_init_ext(const char *name, void (*init)(void));

void Init_console(void);
void Init_wait(void);
void Init_nonblock(void);
void Init_stringio(void);
void Init_ripper(void);
void Init_socket(void);
void Init_date_core(void);
void Init_parser(void);
void Init_generator(void);
void Init_digest(void);
void Init_openssl(void);

void
Init_ext(void)
{
    ruby_init_ext("io/console.so", Init_console);
    ruby_init_ext("io/wait.so", Init_wait);
    ruby_init_ext("io/nonblock.so", Init_nonblock);
    ruby_init_ext("stringio.so", Init_stringio);
    ruby_init_ext("ripper.so", Init_ripper);
    ruby_init_ext("socket.so", Init_socket);
    ruby_init_ext("date_core.so", Init_date_core);
    ruby_init_ext("json/ext/parser.so", Init_parser);
    ruby_init_ext("json/ext/generator.so", Init_generator);
    ruby_init_ext("digest.so", Init_digest);
    ruby_init_ext("openssl.so", Init_openssl);
}

/* Static extension registration for Kurenai.
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
 * date_core, digest, digest/md5, digest/sha1 and etc exist for WEBrick, which
 * requires all of them while loading whether or not a request ever uses them.
 * digest is the same shape as socket: the Ruby half, /digest.rb, is what
 * defines Digest(), and md5init.c requires "digest" to get it.
 *
 * strscan exists for mui, the editor, and its Ruby half -- strscan/strscan.rb,
 * which Init_strscan requires -- is embedded alongside. */

void ruby_init_ext(const char *name, void (*init)(void));

void Init_console(void);
void Init_wait(void);
void Init_nonblock(void);
void Init_stringio(void);
void Init_ripper(void);
void Init_socket(void);
void Init_date_core(void);
void Init_digest(void);
void Init_md5(void);
void Init_sha1(void);
void Init_etc(void);
void Init_strscan(void);

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
    ruby_init_ext("digest.so", Init_digest);
    ruby_init_ext("digest/md5.so", Init_md5);
    ruby_init_ext("digest/sha1.so", Init_sha1);
    ruby_init_ext("etc.so", Init_etc);
    ruby_init_ext("strscan.so", Init_strscan);
}
